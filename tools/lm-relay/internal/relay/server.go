package relay

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/Spe4naz/lm-chat/tools/lm-relay/internal/protocol"
	"github.com/Spe4naz/lm-chat/tools/lm-relay/internal/tunnel"
	"github.com/coder/websocket"
)

// Server is the public relay HTTP handler.
type Server struct {
	cfg             Config
	hub             *hub
	log             *slog.Logger
	responseTimeout time.Duration
	started         time.Time
}

// Version is reported by the status endpoint.
const Version = "0.2.0"

// New builds a relay. The config must already be validated.
func New(cfg Config, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	cfg.applyDefaults()
	timeout, err := cfg.ResponseDuration()
	if err != nil {
		timeout = 5 * time.Minute
	}
	return &Server{
		cfg:             cfg,
		hub:             newHub(),
		log:             logger,
		responseTimeout: timeout,
		started:         time.Now(),
	}
}

// Handler returns the HTTP handler so it can be mounted in tests or behind
// another server.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/_tunnel", s.handleTunnel)
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/d/{device}/{rest...}", s.handleProxy)
	return mux
}

// Run serves until ctx is cancelled.
func (s *Server) Run(ctx context.Context) error {
	srv := &http.Server{
		Addr:              s.cfg.Listen,
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()

	s.log.Info("relay listening", "addr", s.cfg.Listen, "devices", len(s.cfg.Devices))

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
		<-errCh
		return nil
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleTunnel authenticates and registers the agent's outbound WebSocket.
func (s *Server) handleTunnel(w http.ResponseWriter, r *http.Request) {
	deviceID := r.Header.Get("X-Device")
	dev, ok := s.cfg.Devices[deviceID]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown device"})
		return
	}
	if !secureEqual(bearer(r.Header.Get("Authorization")), dev.AgentSecret) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		s.log.Warn("agent upgrade failed", "device", deviceID, "error", err)
		return
	}

	conn := tunnel.NewConn(r.Context(), ws, func(stream *tunnel.Stream, _ protocol.OpenRequest) {
		stream.Reset("relay does not accept streams")
	})
	sess := newSession(deviceID, conn, s.cfg.MaxStreams, s.cfg.RatePerSecond, s.cfg.RateBurst)
	s.hub.add(sess)
	s.log.Info("agent connected", "device", deviceID)

	<-conn.Done()
	s.hub.remove(deviceID, conn)
	conn.Close()
	s.log.Info("agent disconnected", "device", deviceID, "error", conn.Err())
}

// handleProxy authenticates the app and forwards one request to the agent.
func (s *Server) handleProxy(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	status := 0
	written := 0
	deviceID := r.PathValue("device")
	rest := r.PathValue("rest")

	defer func() {
		s.log.Info("relay request",
			"device", deviceID,
			"status", status,
			"ms", time.Since(started).Milliseconds(),
			"bytes", written,
		)
	}()

	if deviceID == "" || rest == "" {
		status = http.StatusNotFound
		writeJSON(w, status, map[string]string{"error": "not found"})
		return
	}
	path := rest
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}

	dev, ok := s.cfg.Devices[deviceID]
	if !ok {
		status = http.StatusNotFound
		writeJSON(w, status, map[string]string{"error": "unknown device"})
		return
	}
	if !secureEqual(r.Header.Get("X-Relay-Token"), dev.AccessToken) {
		status = http.StatusUnauthorized
		writeJSON(w, status, map[string]string{"error": "unauthorized"})
		return
	}

	// The status endpoint is answered by the relay itself: it must work even
	// when the agent is offline.
	if path == "/_relay/status" {
		sess := s.hub.get(deviceID)
		online := sess != nil
		streams := 0
		if online {
			streams = sess.conn.ActiveStreams()
		}
		status = http.StatusOK
		writeJSON(w, status, map[string]any{
			"ok":        true,
			"online":    online,
			"streams":   streams,
			"version":   Version,
			"uptime_ms": time.Since(s.started).Milliseconds(),
		})
		return
	}

	service, ok := routeService(path)
	if !ok {
		status = http.StatusNotFound
		writeJSON(w, status, map[string]string{"error": "not found"})
		return
	}
	if !dev.allows(service) {
		status = http.StatusForbidden
		writeJSON(w, status, map[string]string{"error": "service is not exposed"})
		return
	}
	if r.ContentLength > s.cfg.MaxBodyBytes {
		status = http.StatusRequestEntityTooLarge
		writeJSON(w, status, map[string]string{"error": "request body too large"})
		return
	}

	sess := s.hub.get(deviceID)
	if sess == nil {
		status = http.StatusServiceUnavailable
		w.Header().Set("Retry-After", "5")
		writeJSON(w, status, map[string]string{"error": "agent offline"})
		return
	}
	if !sess.limiter.allow() {
		status = http.StatusTooManyRequests
		writeJSON(w, status, map[string]string{"error": "too many requests"})
		return
	}

	select {
	case sess.slots <- struct{}{}:
		defer func() { <-sess.slots }()
	default:
		status = http.StatusTooManyRequests
		writeJSON(w, status, map[string]string{"error": "too many streams"})
		return
	}

	open := protocol.OpenRequest{
		Service: service,
		Method:  r.Method,
		Path:    path,
		Headers: relayRequestHeaders(r.Header),
		Body:    r.ContentLength != 0,
	}
	if r.URL.RawQuery != "" {
		open.Path += "?" + r.URL.RawQuery
	}

	stream, err := sess.conn.OpenStream(open)
	if err != nil {
		status = http.StatusBadGateway
		writeJSON(w, status, map[string]string{"error": "agent connection lost"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxBodyBytes)
	go s.copyRequestBody(r, stream)

	var resp protocol.Response
	select {
	case resp = <-stream.ResponseChan():
	case <-stream.ResetChan():
		status = http.StatusBadGateway
		writeJSON(w, status, map[string]string{"error": "agent reset the stream"})
		return
	case <-time.After(s.responseTimeout):
		stream.Reset("response timeout")
		status = http.StatusGatewayTimeout
		writeJSON(w, status, map[string]string{"error": "agent response timeout"})
		return
	case <-r.Context().Done():
		stream.Reset("client disconnected")
		return
	}

	if resp.Status < 100 || resp.Status > 599 {
		resp.Status = http.StatusBadGateway
	}
	applyResponseHeaders(w.Header(), resp.Headers)
	if service == protocol.ServiceE2E {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Accel-Buffering", "no")
	}
	status = resp.Status
	w.WriteHeader(status)
	flush(w)

	for {
		chunk, ok, err := stream.NextContext(r.Context())
		if err != nil {
			if r.Context().Err() != nil {
				stream.Reset("client disconnected")
			}
			return
		}
		if !ok {
			return
		}
		n, err := w.Write(chunk)
		written += n
		if err != nil {
			stream.Reset("client write failed")
			return
		}
		flush(w)
	}
}

func (s *Server) copyRequestBody(r *http.Request, stream *tunnel.Stream) {
	defer func() { _ = stream.CloseWrite() }()
	if r.ContentLength == 0 {
		return
	}
	buf := make([]byte, protocol.MaxDataPayload)
	for {
		n, err := r.Body.Read(buf)
		if n > 0 {
			if _, writeErr := stream.Write(buf[:n]); writeErr != nil {
				return
			}
		}
		if err == io.EOF {
			return
		}
		if err != nil {
			stream.Reset("request body read failed")
			return
		}
	}
}

func flush(w http.ResponseWriter) {
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
}

func bearer(value string) string {
	const prefix = "Bearer "
	if len(value) >= len(prefix) && strings.EqualFold(value[:len(prefix)], prefix) {
		return strings.TrimSpace(value[len(prefix):])
	}
	return ""
}

func secureEqual(got, want string) bool {
	if got == "" || want == "" || len(got) != len(want) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		body = []byte(`{"error":"internal"}`)
		status = http.StatusInternalServerError
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(append(body, '\n'))
}
