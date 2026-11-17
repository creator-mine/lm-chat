package tunnel

import "sync"

// window tracks how many bytes the peer may still send on one stream.
//
// The sender waits in take and the receiver wakes it with grant after the
// bytes have been handed to the local HTTP stack. Without this a slow client
// would make the relay buffer an unbounded response in memory.
type window struct {
	mu     sync.Mutex
	cond   *sync.Cond
	credit int64
	closed bool
}

const maxWindow = 1 << 30

func newWindow(n int64) *window {
	w := &window{credit: n}
	w.cond = sync.NewCond(&w.mu)
	return w
}

func (w *window) take(n int) error {
	if n <= 0 {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for w.credit < int64(n) && !w.closed {
		w.cond.Wait()
	}
	if w.closed {
		return errClosed
	}
	w.credit -= int64(n)
	return nil
}

func (w *window) grant(n int) {
	if n <= 0 {
		return
	}
	w.mu.Lock()
	if w.credit < maxWindow {
		w.credit += int64(n)
		if w.credit > maxWindow {
			w.credit = maxWindow
		}
	}
	w.mu.Unlock()
	w.cond.Broadcast()
}

func (w *window) close() {
	w.mu.Lock()
	w.closed = true
	w.mu.Unlock()
	w.cond.Broadcast()
}
