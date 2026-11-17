package relay

import (
	"net/http"
	"net/textproto"
	"strings"
)

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

var relayOnlyHeaders = map[string]bool{
	"X-Relay-Token":     true,
	"X-Forwarded-For":   true,
	"X-Forwarded-Host":  true,
	"X-Forwarded-Proto": true,
	"X-Real-Ip":         true,
}

// relayRequestHeaders prepares headers for the agent. Hop-by-hop headers and
// relay-only credentials never leave the relay; Authorization is preserved
// because the end service still checks its own token.
func relayRequestHeaders(h http.Header) map[string][]string {
	out := make(map[string][]string, len(h))
	for key, values := range h {
		canonical := textproto.CanonicalMIMEHeaderKey(key)
		if hopHeaders[canonical] || relayOnlyHeaders[canonical] {
			continue
		}
		if canonical == "Accept-Encoding" {
			continue
		}
		out[canonical] = append([]string(nil), values...)
	}
	return out
}

// applyResponseHeaders copies the upstream headers to the public response.
// SSE must not be buffered by nginx, so the relay always advertises that.
func applyResponseHeaders(dst http.Header, src map[string][]string) {
	for key, values := range src {
		canonical := textproto.CanonicalMIMEHeaderKey(key)
		if hopHeaders[canonical] {
			continue
		}
		for _, value := range values {
			dst.Add(canonical, value)
		}
	}
	if strings.HasPrefix(dst.Get("Content-Type"), "text/event-stream") {
		dst.Set("X-Accel-Buffering", "no")
		dst.Set("Cache-Control", "no-cache")
	}
}
