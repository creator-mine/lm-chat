package relay_test

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Spe4naz/lm-chat/tools/lm-relay/internal/agent"
	"github.com/Spe4naz/lm-chat/tools/lm-relay/internal/relay"
)

const (
	deviceID    = "test-device"
	accessToken = "access-token-0123456789"
	agentSecret = "agent-secret-0123456789"
)

type stack struct {
	relay  *httptest.Server
	client *http.Client
	cancel context.CancelFunc
}

func newStack(t *testing.T) *stack {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	lm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/v1/models":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"models":[{"id":"test-model"}]}`)
		case r.URL.Path == "/v1/chat/completions":
			body, _ := io.ReadAll(r.Body)
			sum := sha256.Sum256(body)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"len":%d,"sha":%q,"method":%q}`, len(body), hex.EncodeToString(sum[:]), r.Method)
		case r.URL.Path == "/v1/events":
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			flusher, _ := w.(http.Flusher)
			for i := 0; i < 3; i++ {
				fmt.Fprintf(w, "data: %d\n\n", i)
				if flusher != nil {
					flusher.Flush()
				}
				time.Sleep(120 * time.Millisecond)
			}
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(lm.Close)

	plugin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/status":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"ok":true,"version":"test"}`)
		case "/api/shutdown":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"ok":true}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(plugin.Close)

	bridge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"ok":true,"lms":"test"}`)
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(bridge.Close)

	cfg := relay.Config{
		Listen:          "127.0.0.1:0",
		MaxBodyBytes:    4 << 20,
		ResponseTimeout: "10s",
		MaxStreams:      8,
		RatePerSecond:   1000,
		RateBurst:       1000,
		Devices: map[string]relay.Device{
			deviceID: {
				AgentSecret: agentSecret,
				AccessToken: accessToken,
			},
		},
	}
	relayServer := httptest.NewServer(relay.New(cfg, logger).Handler())
	t.Cleanup(relayServer.Close)

	agentCfg := agent.Config{
		RelayURL:    "ws" + strings.TrimPrefix(relayServer.URL, "http") + "/_tunnel",
		DeviceID:    deviceID,
		AgentSecret: agentSecret,
		Services: map[string]string{
			"lmstudio": lm.URL,
			"bridge":   bridge.URL,
			"plugin":   plugin.URL,
		},
	}
	runner, err := agent.New(agentCfg, logger)
	if err != nil {
		t.Fatalf("agent: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = runner.Run(ctx) }()

	s := &stack{
		relay:  relayServer,
		client: &http.Client{Timeout: 15 * time.Second},
		cancel: cancel,
	}
	s.waitOnline(t)
	return s
}

func (s *stack) waitOnline(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		resp, _, err := s.request(t, http.MethodGet, "/api/status", nil, accessToken)
		if err == nil && resp.StatusCode == http.StatusOK {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("agent did not come online: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (s *stack) request(t *testing.T, method, path string, body io.Reader, token string) (*http.Response, []byte, error) {
	t.Helper()
	req, err := http.NewRequest(method, s.relay.URL+"/d/"+deviceID+path, body)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("X-Relay-Token", token)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	data, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return resp, nil, err
	}
	return resp, data, nil
}

func TestRoutesAndAuth(t *testing.T) {
	s := newStack(t)

	resp, body, err := s.request(t, http.MethodGet, "/api/status", nil, accessToken)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("plugin status: %v %d %s", err, resp.StatusCode, body)
	}
	if !bytes.Contains(body, []byte(`"version":"test"`)) {
		t.Fatalf("unexpected plugin body: %s", body)
	}

	resp, body, err = s.request(t, http.MethodGet, "/health", nil, accessToken)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("bridge health: %v %d %s", err, resp.StatusCode, body)
	}
	if !bytes.Contains(body, []byte(`"lms":"test"`)) {
		t.Fatalf("unexpected bridge body: %s", body)
	}

	resp, body, err = s.request(t, http.MethodGet, "/api/v1/models", nil, accessToken)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("models: %v %d %s", err, resp.StatusCode, body)
	}
	if !bytes.Contains(body, []byte("test-model")) {
		t.Fatalf("unexpected models body: %s", body)
	}

	resp, _, err = s.request(t, http.MethodGet, "/api/status", nil, "")
	if err != nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing token: %v %d", err, resp.StatusCode)
	}

	resp, _, err = s.request(t, http.MethodGet, "/api/status", nil, "wrong-token-0123456789")
	if err != nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong token: %v %d", err, resp.StatusCode)
	}

	unknown := s.relay.URL + "/d/other/api/status"
	req, _ := http.NewRequest(http.MethodGet, unknown, nil)
	req.Header.Set("X-Relay-Token", accessToken)
	resp, err = s.client.Do(req)
	if err != nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown device: %v %d", err, resp.StatusCode)
	}
	resp.Body.Close()
}

func TestStreamsLargeRequestBody(t *testing.T) {
	s := newStack(t)

	payload := bytes.Repeat([]byte("a"), 2<<20)
	sum := sha256.Sum256(payload)
	resp, body, err := s.request(t, http.MethodPost, "/v1/chat/completions", bytes.NewReader(payload), accessToken)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d: %s", resp.StatusCode, body)
	}
	want := fmt.Sprintf(`"len":%d,"sha":%q`, len(payload), hex.EncodeToString(sum[:]))
	if !bytes.Contains(body, []byte(want)) {
		t.Fatalf("body was truncated or changed: %s", body)
	}
}

func TestStreamsSSEWithoutBuffering(t *testing.T) {
	s := newStack(t)

	started := time.Now()
	req, err := http.NewRequest(http.MethodGet, s.relay.URL+"/d/"+deviceID+"/v1/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-Relay-Token", accessToken)
	resp, err := s.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}

	var stamps []time.Time
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), "data:") {
			stamps = append(stamps, time.Now())
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if len(stamps) != 3 {
		t.Fatalf("got %d events, want 3", len(stamps))
	}
	if stamps[0].Sub(started) > 800*time.Millisecond {
		t.Fatalf("first event arrived after %s, the relay is buffering", stamps[0].Sub(started))
	}
	if stamps[2].Sub(stamps[0]) < 150*time.Millisecond {
		t.Fatalf("events arrived together, the relay is buffering")
	}
}

func TestOfflineAgentReturns503(t *testing.T) {
	s := newStack(t)
	s.cancel()

	deadline := time.Now().Add(5 * time.Second)
	for {
		resp, _, err := s.request(t, http.MethodGet, "/api/status", nil, accessToken)
		if err == nil && resp.StatusCode == http.StatusServiceUnavailable {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("agent stayed online: %v %d", err, resp.StatusCode)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestShutdownNeedsConfirmation(t *testing.T) {
	s := newStack(t)

	resp, _, err := s.request(t, http.MethodPost, "/api/shutdown", nil, accessToken)
	if err != nil || resp.StatusCode != http.StatusForbidden {
		t.Fatalf("shutdown without confirmation: %v %d", err, resp.StatusCode)
	}

	req, _ := http.NewRequest(http.MethodPost, s.relay.URL+"/d/"+deviceID+"/api/shutdown", nil)
	req.Header.Set("X-Relay-Token", accessToken)
	req.Header.Set("X-Relay-Confirm", "shutdown")
	resp, err = s.client.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("shutdown with confirmation: %v %d", err, resp.StatusCode)
	}
	resp.Body.Close()
}
