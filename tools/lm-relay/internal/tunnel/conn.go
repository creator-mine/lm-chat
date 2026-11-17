package tunnel

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Spe4naz/lm-chat/tools/lm-relay/internal/protocol"
	"github.com/coder/websocket"
)

// OpenHandler serves an incoming request stream. The agent sets it; the relay
// only expects responses and rejects unsolicited OPEN frames.
type OpenHandler func(*Stream, protocol.OpenRequest)

// Conn multiplexes HTTP streams over one WebSocket connection.
type Conn struct {
	ws     *websocket.Conn
	onOpen OpenHandler

	ctx    context.Context
	cancel context.CancelFunc

	writeMu sync.Mutex
	mu      sync.Mutex
	streams map[uint32]*Stream
	next    atomic.Uint32

	closeOnce sync.Once
	done      chan struct{}
	errMu     sync.Mutex
	err       error
}

// NewConn starts the read and keepalive loops. Cancelling ctx closes the
// connection. The caller must not use ws afterwards.
func NewConn(ctx context.Context, ws *websocket.Conn, onOpen OpenHandler) *Conn {
	connCtx, cancel := context.WithCancel(ctx)
	c := &Conn{
		ws:      ws,
		onOpen:  onOpen,
		ctx:     connCtx,
		cancel:  cancel,
		streams: make(map[uint32]*Stream),
		done:    make(chan struct{}),
	}
	ws.SetReadLimit(protocol.HeaderSize + protocol.MaxPayload)
	go c.readLoop()
	go c.keepalive()
	return c
}

// Done is closed when the connection ends.
func (c *Conn) Done() <-chan struct{} { return c.done }

// Err reports why the connection ended.
func (c *Conn) Err() error {
	c.errMu.Lock()
	defer c.errMu.Unlock()
	if c.err != nil {
		return c.err
	}
	return errClosed
}

// ActiveStreams is the number of streams that have not ended yet.
func (c *Conn) ActiveStreams() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.streams)
}

// Close ends the connection.
func (c *Conn) Close() { c.shutdown(errClosed) }

// OpenStream starts a request stream and sends OPEN to the peer.
func (c *Conn) OpenStream(req protocol.OpenRequest) (*Stream, error) {
	select {
	case <-c.ctx.Done():
		return nil, errClosed
	default:
	}

	id := c.nextID()
	s := newStream(c, id)
	c.mu.Lock()
	c.streams[id] = s
	c.mu.Unlock()

	payload, err := protocol.Marshal(req)
	if err != nil {
		c.dropStream(id)
		s.abort(err)
		return nil, err
	}
	if err := c.writeFrame(protocol.Frame{
		Type:    protocol.TypeOpen,
		Stream:  id,
		Payload: payload,
	}); err != nil {
		c.dropStream(id)
		s.abort(err)
		return nil, err
	}
	return s, nil
}

func (c *Conn) nextID() uint32 {
	for {
		id := c.next.Add(1)
		if id != 0 {
			return id
		}
	}
}

func (c *Conn) writeFrame(f protocol.Frame) error {
	buf, err := f.Encode()
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	select {
	case <-c.ctx.Done():
		return errClosed
	default:
	}
	ctx, cancel := context.WithTimeout(c.ctx, 30*time.Second)
	defer cancel()
	return c.ws.Write(ctx, websocket.MessageBinary, buf)
}

func (c *Conn) readLoop() {
	for {
		_, data, err := c.ws.Read(c.ctx)
		if err != nil {
			c.shutdown(err)
			return
		}
		frame, err := protocol.Decode(data)
		if err != nil {
			c.shutdown(err)
			return
		}
		if err := c.handleFrame(frame); err != nil {
			c.shutdown(err)
			return
		}
	}
}

func (c *Conn) handleFrame(f protocol.Frame) error {
	if f.Stream == 0 {
		return fmt.Errorf("protocol: frame %s with stream 0", f.Type)
	}
	switch f.Type {
	case protocol.TypeOpen:
		return c.handleOpen(f)
	case protocol.TypeData:
		if len(f.Payload) > protocol.MaxDataPayload {
			c.resetRemote(f.Stream, "data frame too large")
			return nil
		}
		if s := c.stream(f.Stream); s != nil {
			s.deliverData(f.Payload)
		}
	case protocol.TypeEnd:
		if s := c.stream(f.Stream); s != nil {
			s.deliverEnd()
		}
	case protocol.TypeReset:
		var reset protocol.Reset
		_ = protocol.Unmarshal(f.Payload, &reset)
		if s := c.stream(f.Stream); s != nil {
			err := ErrReset
			if reset.Reason != "" {
				err = fmt.Errorf("%w: %s", ErrReset, reset.Reason)
			}
			s.deliverReset(err)
		}
	case protocol.TypeResponse:
		var resp protocol.Response
		if err := protocol.Unmarshal(f.Payload, &resp); err != nil {
			c.resetRemote(f.Stream, "bad response")
			return nil
		}
		if s := c.stream(f.Stream); s != nil {
			s.deliverResponse(resp)
		}
	case protocol.TypeWindow:
		n, err := protocol.DecodeWindow(f.Payload)
		if err != nil {
			c.resetRemote(f.Stream, "bad window")
			return nil
		}
		if s := c.stream(f.Stream); s != nil {
			s.win.grant(int(n))
		}
	default:
		return fmt.Errorf("protocol: unexpected frame %s", f.Type)
	}
	return nil
}

func (c *Conn) handleOpen(f protocol.Frame) error {
	var req protocol.OpenRequest
	if err := protocol.Unmarshal(f.Payload, &req); err != nil {
		c.resetRemote(f.Stream, "bad open")
		return nil
	}
	c.mu.Lock()
	if _, exists := c.streams[f.Stream]; exists {
		c.mu.Unlock()
		c.resetRemote(f.Stream, "duplicate stream")
		return nil
	}
	s := newStream(c, f.Stream)
	c.streams[f.Stream] = s
	c.mu.Unlock()

	if c.onOpen == nil {
		s.Reset("no open handler")
		return nil
	}
	go c.onOpen(s, req)
	return nil
}

func (c *Conn) resetRemote(id uint32, reason string) {
	payload, err := protocol.Marshal(protocol.Reset{Reason: reason})
	if err != nil {
		return
	}
	_ = c.writeFrame(protocol.Frame{
		Type:    protocol.TypeReset,
		Stream:  id,
		Payload: payload,
	})
}

func (c *Conn) stream(id uint32) *Stream {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.streams[id]
}

func (c *Conn) dropStream(id uint32) {
	c.mu.Lock()
	delete(c.streams, id)
	c.mu.Unlock()
}

func (c *Conn) keepalive() {
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(c.ctx, 10*time.Second)
			err := c.ws.Ping(ctx)
			cancel()
			if err != nil {
				c.shutdown(err)
				return
			}
		}
	}
}

func (c *Conn) shutdown(err error) {
	c.closeOnce.Do(func() {
		if err == nil || errors.Is(err, context.Canceled) {
			err = errClosed
		}
		c.errMu.Lock()
		c.err = err
		c.errMu.Unlock()

		c.cancel()
		_ = c.ws.CloseNow()

		c.mu.Lock()
		streams := make([]*Stream, 0, len(c.streams))
		for _, s := range c.streams {
			streams = append(streams, s)
		}
		c.streams = make(map[uint32]*Stream)
		c.mu.Unlock()

		for _, s := range streams {
			s.abort(err)
		}
		close(c.done)
	})
}
