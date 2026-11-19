package tunnel

import (
	"context"
	"errors"
	"io"
	"sync"
	"sync/atomic"

	"github.com/creator-mine/lm-chat/tools/lm-relay/internal/protocol"
)

// initialWindow is how many bytes either side may send on a new stream before
// it has to wait for a WINDOW frame.
const initialWindow = 1 << 20

var (
	errClosed = errors.New("tunnel: closed")
	// ErrReset is returned when the peer aborted a stream.
	ErrReset = errors.New("tunnel: stream reset")
	errFlow  = errors.New("tunnel: flow-control overflow")
)

// Stream is one HTTP request/response pair multiplexed over the connection.
type Stream struct {
	id   uint32
	conn *Conn
	win  *window

	in      chan []byte
	resp    chan protocol.Response
	endCh   chan struct{}
	resetCh chan struct{}
	done    chan struct{}

	writeClosed atomic.Bool
	endOnce     sync.Once
	resetOnce   sync.Once
	doneOnce    sync.Once

	errMu sync.Mutex
	err   error

	bytesOut atomic.Int64
}

func newStream(conn *Conn, id uint32) *Stream {
	capacity := initialWindow/protocol.MaxDataPayload + 8
	return &Stream{
		id:      id,
		conn:    conn,
		win:     newWindow(initialWindow),
		in:      make(chan []byte, capacity),
		resp:    make(chan protocol.Response, 1),
		endCh:   make(chan struct{}),
		resetCh: make(chan struct{}),
		done:    make(chan struct{}),
	}
}

// ID returns the stream identifier.
func (s *Stream) ID() uint32 { return s.id }

// BytesOut is the number of data bytes written to the peer.
func (s *Stream) BytesOut() int64 { return s.bytesOut.Load() }

// Done is closed when the stream ends or is reset.
func (s *Stream) Done() <-chan struct{} { return s.done }

// ResetChan is closed on abort.
func (s *Stream) ResetChan() <-chan struct{} { return s.resetCh }

// EndChan is closed when the peer half-closes its direction.
func (s *Stream) EndChan() <-chan struct{} { return s.endCh }

// ResponseChan delivers the upstream status line.
func (s *Stream) ResponseChan() <-chan protocol.Response { return s.resp }

// Err is the reason the stream was reset.
func (s *Stream) Err() error {
	s.errMu.Lock()
	defer s.errMu.Unlock()
	if s.err != nil {
		return s.err
	}
	return ErrReset
}

func (s *Stream) setErr(err error) {
	s.errMu.Lock()
	if s.err == nil {
		s.err = err
	}
	s.errMu.Unlock()
}

func (s *Stream) markDone() {
	s.doneOnce.Do(func() { close(s.done) })
}

// Write sends request or response bytes, respecting the peer's window.
func (s *Stream) Write(p []byte) (int, error) {
	if s.writeClosed.Load() {
		return 0, errClosed
	}
	total := 0
	for len(p) > 0 {
		select {
		case <-s.resetCh:
			return total, s.Err()
		default:
		}

		n := len(p)
		if n > protocol.MaxDataPayload {
			n = protocol.MaxDataPayload
		}
		if err := s.win.take(n); err != nil {
			return total, s.Err()
		}
		if err := s.conn.writeFrame(protocol.Frame{
			Type:    protocol.TypeData,
			Stream:  s.id,
			Payload: p[:n],
		}); err != nil {
			return total, err
		}
		total += n
		s.bytesOut.Add(int64(n))
		p = p[n:]
	}
	return total, nil
}

// CloseWrite half-closes the sending direction.
func (s *Stream) CloseWrite() error {
	if !s.writeClosed.CompareAndSwap(false, true) {
		return nil
	}
	return s.conn.writeFrame(protocol.Frame{Type: protocol.TypeEnd, Stream: s.id})
}

// SendResponse sends the upstream status and headers.
func (s *Stream) SendResponse(status int, headers map[string][]string) error {
	payload, err := protocol.Marshal(protocol.Response{Status: status, Headers: headers})
	if err != nil {
		return err
	}
	return s.conn.writeFrame(protocol.Frame{
		Type:    protocol.TypeResponse,
		Stream:  s.id,
		Payload: payload,
	})
}

// Reset aborts the stream in both directions.
func (s *Stream) Reset(reason string) {
	payload, err := protocol.Marshal(protocol.Reset{Reason: reason})
	if err == nil {
		_ = s.conn.writeFrame(protocol.Frame{
			Type:    protocol.TypeReset,
			Stream:  s.id,
			Payload: payload,
		})
	}
	s.abort(ErrReset)
}

func (s *Stream) abort(err error) {
	s.resetOnce.Do(func() {
		s.setErr(err)
		close(s.resetCh)
		s.win.close()
		s.markDone()
		s.conn.dropStream(s.id)
	})
}

func (s *Stream) deliverData(p []byte) {
	if len(p) == 0 {
		return
	}
	if len(p) > protocol.MaxDataPayload {
		s.abort(errFlow)
		return
	}
	buf := make([]byte, len(p))
	copy(buf, p)
	select {
	case s.in <- buf:
	default:
		s.abort(errFlow)
	}
}

func (s *Stream) deliverResponse(r protocol.Response) {
	select {
	case s.resp <- r:
	default:
		s.abort(errFlow)
	}
}

func (s *Stream) deliverEnd() {
	s.endOnce.Do(func() { close(s.endCh) })
	s.markDone()
	s.conn.dropStream(s.id)
}

func (s *Stream) deliverReset(err error) {
	if err == nil {
		err = ErrReset
	}
	s.abort(err)
}

// Next returns the next response chunk. ok is false after a clean end.
// Every returned chunk is acknowledged to the sender with a WINDOW frame.
func (s *Stream) Next() ([]byte, bool, error) {
	return s.NextContext(context.Background())
}

// NextContext is Next with cancellation, so a relay handler can stop waiting
// when the app closes the request.
func (s *Stream) NextContext(ctx context.Context) ([]byte, bool, error) {
	select {
	case b := <-s.in:
		s.grantPeer(len(b))
		return b, true, nil
	default:
	}

	select {
	case b := <-s.in:
		s.grantPeer(len(b))
		return b, true, nil
	case <-s.endCh:
		select {
		case b := <-s.in:
			s.grantPeer(len(b))
			return b, true, nil
		default:
			return nil, false, nil
		}
	case <-s.resetCh:
		return nil, false, s.Err()
	case <-ctx.Done():
		return nil, false, ctx.Err()
	}
}

// Reader adapts the incoming direction to io.Reader, used by the agent for
// request bodies.
func (s *Stream) Reader() io.Reader { return &streamReader{s: s} }

// grantPeer returns flow-control credit for n consumed bytes. The sender
// starts with initialWindow and can only continue after these frames arrive.
func (s *Stream) grantPeer(n int) {
	if n <= 0 {
		return
	}
	_ = s.conn.writeFrame(protocol.Frame{
		Type:    protocol.TypeWindow,
		Stream:  s.id,
		Payload: protocol.EncodeWindow(uint32(n)),
	})
}

type streamReader struct {
	s       *Stream
	pending []byte
}

func (r *streamReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for len(r.pending) == 0 {
		b, ok, err := r.s.Next()
		if err != nil {
			return 0, err
		}
		if !ok {
			return 0, io.EOF
		}
		r.pending = b
	}
	n := copy(p, r.pending)
	r.pending = r.pending[n:]
	return n, nil
}
