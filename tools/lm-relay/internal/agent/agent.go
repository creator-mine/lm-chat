// Package agent runs next to LM Studio, keeps an outbound WebSocket to the
// relay and forwards tunneled requests to the local services.
package agent

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"path"
	"strings"
	"time"

	"github.com/creator-mine/lm-chat/tools/lm-relay/internal/e2e"
	"github.com/creator-mine/lm-chat/tools/lm-relay/internal/protocol"
	"github.com/creator-mine/lm-chat/tools/lm-relay/internal/tunnel"
	"github.com/coder/websocket"
)

const maxStreams = 64

// agentMaxBody bounds the decrypted E2E request body that the agent buffers
// before it answers. It matches the relay's default max_body_bytes.
const agentMaxBody = 16 << 20

var errShutdownBlocked = errors.New("shutdown is disabled")

var hopHeaders = map[string]bool{
	"Connection":          true,
	"Proxy-Connection":    true,
	"Keep-Alive":          true,
	"Proxy-Authenticate":  true,
	"Proxy-Authorization": true,
	"Te":                  true,
	"Trailer":             true,
	"Transfer-Encoding":   true,
	"Upgrade":             true,
}

// Agent is the outbound tunnel client.
type Agent struct {
	cfg      Config
	log      *slog.Logger
	client   *http.Client
	wsClient *http.Client
	slots    chan struct{}
	identity *e2e.Identity
}

// New validates the configuration and builds the HTTP clients.
func New(cfg Config, logger *slog.Logger) (*Agent, error) {
	if logger == nil {
		logger = slog.Default()
	}
	cfg.applyDefaults()
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	if cfg.IdentityFile == "" {
		path, err := e2e.DefaultIdentityPath()
		if err != nil {
			return nil, err
		}
		cfg.IdentityFile = path
	}
	identity, err := e2e.LoadOrCreateIdentity(cfg.IdentityFile)
	if err != nil {
		return nil, err
	}
	logger.Info("e2e identity",
		"public_key", identity.PublicKey(),
		"fingerprint", identity.Fingerprint(),
	)

	var tlsConfig *tls.Config
	if cfg.CAFile != "" {
		pem, err := os.ReadFile(cfg.CAFile)
		if err != nil {
			return nil, fmt.Errorf("agent: ca_file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("agent: ca_file contains no certificates")
		}
		tlsConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}

	return &Agent{
		cfg:      cfg,
		log:      logger,
		client:   &http.Client{Transport: newTransport(tlsConfig)},
		wsClient: &http.Client{Transport: newTransport(tlsConfig)},
		slots:    make(chan struct{}, maxStreams),
		identity: identity,
	}, nil
}

// PublicKey is the base64 X25519 key the app pins for E2E.
func (a *Agent) PublicKey() string {
	if a.identity == nil {
		return ""
	}
	return a.identity.PublicKey()
}

// Fingerprint is the grouped SHA-256 of the identity key.
func (a *Agent) Fingerprint() string {
	if a.identity == nil {
		return ""
	}
	return a.identity.Fingerprint()
}

func newTransport(tlsConfig *tls.Config) *http.Transport {
	return &http.Transport{
		Proxy:                 nil,
		DialContext:           (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2:     false,
		MaxIdleConns:          32,
		MaxIdleConnsPerHost:   8,
		IdleConnTimeout:       90 * time.Second,
		ResponseHeaderTimeout: 0,
		ExpectContinueTimeout: time.Second,
		DisableCompression:    true,
		TLSClientConfig:       tlsConfig,
	}
}

// Run keeps the tunnel alive until ctx is cancelled.
func (a *Agent) Run(ctx context.Context) error {
	backoff := time.Second
	for {
		started := time.Now()
		err := a.session(ctx)
		if ctx.Err() != nil {
			return nil
		}
		if time.Since(started) > 30*time.Second {
			backoff = time.Second
		}
		a.log.Warn("relay session ended", "error", err, "retry_in", backoff.Round(time.Millisecond))
		delay := time.Duration(float64(backoff) * (0.8 + 0.4*rand.Float64()))
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay):
		}
		if backoff < 30*time.Second {
			backoff *= 2
			if backoff > 30*time.Second {
				backoff = 30 * time.Second
			}
		}
	}
}

func (a *Agent) session(ctx context.Context) error {
	header := http.Header{}
	header.Set("X-Device", a.cfg.DeviceID)
	header.Set("Authorization", "Bearer "+a.cfg.AgentSecret)

	ws, resp, err := websocket.Dial(ctx, a.cfg.RelayURL, &websocket.DialOptions{
		HTTPHeader:      header,
		HTTPClient:      a.wsClient,
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		if resp != nil {
			return fmt.Errorf("dial relay: %s (%w)", resp.Status, err)
		}
		return fmt.Errorf("dial relay: %w", err)
	}

	a.log.Info("relay connected", "url", a.cfg.RelayURL, "device", a.cfg.DeviceID)
	conn := tunnel.NewConn(ctx, ws, a.handleOpen)
	<-conn.Done()
	return conn.Err()
}

func (a *Agent) handleOpen(stream *tunnel.Stream, req protocol.OpenRequest) {
	select {
	case a.slots <- struct{}{}:
		defer func() { <-a.slots }()
	default:
		stream.Reset("agent busy")
		return
	}

	started := time.Now()
	status := 0
	defer func() {
		a.log.Info("relay request",
			"service", req.Service,
			"status", status,
			"ms", time.Since(started).Milliseconds(),
			"out_bytes", stream.BytesOut(),
		)
	}()

	if req.Service == protocol.ServiceE2E {
		status = a.handleE2E(stream)
		return
	}

	target, err := a.target(req)
	if err != nil {
		if errors.Is(err, errShutdownBlocked) {
			status = http.StatusForbidden
			writeAgentError(stream, status, "shutdown is disabled")
		} else {
			status = http.StatusBadRequest
			writeAgentError(stream, status, err.Error())
		}
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		select {
		case <-stream.ResetChan():
			cancel()
		case <-ctx.Done():
		}
	}()

	var body io.Reader
	if req.Body {
		body = stream.Reader()
	}
	httpReq, err := http.NewRequestWithContext(ctx, req.Method, target, body)
	if err != nil {
		status = http.StatusBadRequest
		writeAgentError(stream, status, "invalid request")
		return
	}
	addForwardHeaders(httpReq, req.Headers)

	resp, err := a.client.Do(httpReq)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		status = http.StatusBadGateway
		writeAgentError(stream, status, "local service unavailable")
		return
	}
	defer resp.Body.Close()

	status = resp.StatusCode
	if err := stream.SendResponse(status, responseHeaders(resp.Header)); err != nil {
		return
	}

	buf := make([]byte, protocol.MaxDataPayload)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, err := stream.Write(buf[:n]); err != nil {
				return
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			stream.Reset("local read failed")
			return
		}
	}
	_ = stream.CloseWrite()
}

// handleE2E decrypts one request, proxies it and encrypts the response.
// The relay only sees opaque frames on the `e2e` service.
func (a *Agent) handleE2E(stream *tunnel.Stream) int {
	if a.identity == nil {
		stream.Reset("e2e is not configured")
		return 0
	}
	// The relay needs an outer 200 before it starts streaming opaque frames.
	// It is sent after the request body is read so a large upload never races
	// with an early response.
	reader := stream.Reader()

	hello := make([]byte, e2e.HelloSize)
	if _, err := io.ReadFull(reader, hello); err != nil {
		_ = sendE2EOuter(stream)
		stream.Reset("e2e hello failed")
		return 0
	}
	session, err := e2e.NewAgentSession(a.identity, hello)
	if err != nil {
		_ = sendE2EOuter(stream)
		stream.Reset("e2e handshake failed")
		return 0
	}
	if err := e2e.WriteFrame(stream, session, []byte(`{"ok":true}`)); err != nil {
		return 0
	}

	headerFrame, err := e2e.ReadFrame(reader, session)
	if err != nil {
		_ = sendE2EOuter(stream)
		stream.Reset("e2e header failed")
		return 0
	}
	var req protocol.OpenRequest
	if err := json.Unmarshal(headerFrame, &req); err != nil {
		_ = sendE2EOuter(stream)
		stream.Reset("e2e header failed")
		return 0
	}
	req.Headers = canonicalHeaders(req.Headers)

	target, err := a.target(req)
	if err != nil {
		_ = sendE2EOuter(stream)
		if errors.Is(err, errShutdownBlocked) {
			writeE2EError(stream, session, http.StatusForbidden, "shutdown is disabled")
			return http.StatusForbidden
		}
		writeE2EError(stream, session, http.StatusBadRequest, err.Error())
		return http.StatusBadRequest
	}

	var bodyBytes []byte
	if req.Body {
		bodyBytes, err = io.ReadAll(io.LimitReader(
			e2e.NewBodyReader(reader, session),
			agentMaxBody+1,
		))
		if err != nil {
			_ = sendE2EOuter(stream)
			stream.Reset("e2e body failed")
			return 0
		}
		if len(bodyBytes) > agentMaxBody {
			_ = sendE2EOuter(stream)
			writeE2EError(stream, session, http.StatusRequestEntityTooLarge, "request body too large")
			return http.StatusRequestEntityTooLarge
		}
	}

	if err := sendE2EOuter(stream); err != nil {
		return 0
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		select {
		case <-stream.ResetChan():
			cancel()
		case <-ctx.Done():
		}
	}()

	var body io.Reader
	if req.Body {
		body = bytes.NewReader(bodyBytes)
	}
	httpReq, err := http.NewRequestWithContext(ctx, req.Method, target, body)
	if err != nil {
		writeE2EError(stream, session, http.StatusBadRequest, "invalid request")
		return http.StatusBadRequest
	}
	addForwardHeaders(httpReq, req.Headers)

	resp, err := a.client.Do(httpReq)
	if err != nil {
		if ctx.Err() != nil {
			return 0
		}
		writeE2EError(stream, session, http.StatusBadGateway, "local service unavailable")
		return http.StatusBadGateway
	}
	defer resp.Body.Close()

	header, err := json.Marshal(protocol.Response{
		Status:  resp.StatusCode,
		Headers: responseHeaders(resp.Header),
	})
	if err != nil {
		stream.Reset("e2e response failed")
		return 0
	}
	if err := e2e.WriteFrame(stream, session, header); err != nil {
		return 0
	}

	buf := make([]byte, protocol.MaxDataPayload)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if err := e2e.WriteFrame(stream, session, buf[:n]); err != nil {
				return resp.StatusCode
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			stream.Reset("local read failed")
			return resp.StatusCode
		}
	}
	_ = stream.CloseWrite()
	return resp.StatusCode
}

func sendE2EOuter(stream *tunnel.Stream) error {
	return stream.SendResponse(http.StatusOK, map[string][]string{
		"Content-Type": {"application/octet-stream"},
	})
}

func writeE2EError(stream *tunnel.Stream, session *e2e.Session, status int, message string) {
	header, _ := json.Marshal(protocol.Response{
		Status:  status,
		Headers: map[string][]string{"Content-Type": {"application/json; charset=utf-8"}},
	})
	if e2e.WriteFrame(stream, session, header) != nil {
		return
	}
	body, _ := json.Marshal(map[string]string{"error": message})
	_ = e2e.WriteFrame(stream, session, body)
	_ = stream.CloseWrite()
}

func canonicalHeaders(headers map[string][]string) map[string][]string {
	if headers == nil {
		return nil
	}
	out := make(map[string][]string, len(headers))
	for key, values := range headers {
		out[textproto.CanonicalMIMEHeaderKey(key)] = values
	}
	return out
}

func addForwardHeaders(dst *http.Request, headers map[string][]string) {
	for key, values := range headers {
		canonical := textproto.CanonicalMIMEHeaderKey(key)
		if hopHeaders[canonical] || canonical == "Host" || canonical == "Content-Length" || canonical == "X-Relay-Confirm" {
			continue
		}
		for _, value := range values {
			dst.Header.Add(canonical, value)
		}
	}
}

func (a *Agent) target(req protocol.OpenRequest) (string, error) {
	base, ok := a.cfg.Services[req.Service]
	if !ok {
		return "", fmt.Errorf("service %q is not configured", req.Service)
	}
	if !allowedMethod(req.Method) {
		return "", fmt.Errorf("method %q is not allowed", req.Method)
	}
	if strings.HasPrefix(req.Path, "//") {
		return "", fmt.Errorf("invalid path")
	}
	u, err := url.ParseRequestURI(req.Path)
	if err != nil || u.IsAbs() || u.Host != "" {
		return "", fmt.Errorf("invalid path")
	}
	if u.Path == "" || path.Clean(u.Path) != u.Path {
		return "", fmt.Errorf("invalid path")
	}
	if req.Service == protocol.ServicePlugin && u.Path == "/api/shutdown" && !a.cfg.AllowShutdown {
		if !strings.EqualFold(headerValue(req.Headers, "X-Relay-Confirm"), "shutdown") {
			return "", errShutdownBlocked
		}
	}
	return strings.TrimRight(base, "/") + req.Path, nil
}

func allowedMethod(method string) bool {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut,
		http.MethodPatch, http.MethodDelete, http.MethodOptions:
		return true
	default:
		return false
	}
}

func headerValue(headers map[string][]string, key string) string {
	return http.Header(headers).Get(key)
}

func responseHeaders(h http.Header) map[string][]string {
	out := make(map[string][]string, len(h))
	for key, values := range h {
		canonical := textproto.CanonicalMIMEHeaderKey(key)
		if hopHeaders[canonical] {
			continue
		}
		out[canonical] = append([]string(nil), values...)
	}
	return out
}

func writeAgentError(stream *tunnel.Stream, status int, message string) {
	body, _ := json.Marshal(map[string]string{"error": message})
	_ = stream.SendResponse(status, map[string][]string{
		"Content-Type": {"application/json; charset=utf-8"},
	})
	_, _ = stream.Write(body)
	_ = stream.CloseWrite()
}
