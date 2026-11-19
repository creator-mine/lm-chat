package relay

import (
	"math"
	"sync"
	"time"

	"github.com/creator-mine/lm-chat/tools/lm-relay/internal/tunnel"
)

// session is one connected agent plus its per-device limits.
type session struct {
	device  string
	conn    *tunnel.Conn
	slots   chan struct{}
	limiter *rateLimiter
}

func newSession(device string, conn *tunnel.Conn, maxStreams int, rate, burst float64) *session {
	return &session{
		device:  device,
		conn:    conn,
		slots:   make(chan struct{}, maxStreams),
		limiter: newRateLimiter(rate, burst),
	}
}

// hub keeps the current connection for every device. A new connection from
// the same device replaces the old one so a restarted agent does not leave a
// stale session behind.
type hub struct {
	mu       sync.RWMutex
	sessions map[string]*session
}

func newHub() *hub {
	return &hub{sessions: make(map[string]*session)}
}

func (h *hub) add(s *session) {
	h.mu.Lock()
	old := h.sessions[s.device]
	h.sessions[s.device] = s
	h.mu.Unlock()
	if old != nil && old.conn != nil {
		old.conn.Close()
	}
}

func (h *hub) get(device string) *session {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.sessions[device]
}

func (h *hub) remove(device string, conn *tunnel.Conn) {
	h.mu.Lock()
	if current := h.sessions[device]; current != nil && current.conn == conn {
		delete(h.sessions, device)
	}
	h.mu.Unlock()
}

// rateLimiter is a small token bucket. It is per device, so one busy client
// cannot starve the others.
type rateLimiter struct {
	mu     sync.Mutex
	tokens float64
	last   time.Time
	rate   float64
	burst  float64
}

func newRateLimiter(rate, burst float64) *rateLimiter {
	return &rateLimiter{
		tokens: burst,
		last:   time.Now(),
		rate:   rate,
		burst:  burst,
	}
}

func (l *rateLimiter) allow() bool {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	l.tokens = math.Min(l.burst, l.tokens+now.Sub(l.last).Seconds()*l.rate)
	l.last = now
	if l.tokens < 1 {
		return false
	}
	l.tokens--
	return true
}
