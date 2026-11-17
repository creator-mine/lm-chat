// Package protocol defines the framing used between the relay and the agent.
//
// Every WebSocket binary message carries exactly one frame:
//
//	version(1) type(1) stream(4, BE) length(4, BE) payload(length)
//
// Control frames (OPEN, RESPONSE, RESET, WINDOW) carry JSON or fixed-size
// payloads; DATA frames carry raw request/response bytes.
package protocol

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
)

const (
	// Version is bumped when the frame layout or the control payloads change
	// incompatibly. The relay refuses sessions with another version.
	Version = 1

	// HeaderSize is the fixed part of every frame.
	HeaderSize = 10

	// MaxPayload bounds a single WebSocket message so a broken peer cannot make
	// the other side allocate an arbitrary buffer.
	MaxPayload = 1 << 20

	// MaxDataPayload is the largest DATA payload either side sends. Small
	// frames keep the shared WebSocket connection fair between streams.
	MaxDataPayload = 32 << 10

	// MaxControlPayload bounds OPEN and RESPONSE JSON.
	MaxControlPayload = 64 << 10
)

// Type is the frame kind.
type Type byte

const (
	// TypeOpen starts a request stream (relay -> agent).
	TypeOpen Type = iota + 1
	// TypeData carries request or response bytes.
	TypeData
	// TypeEnd half-closes the sending direction.
	TypeEnd
	// TypeReset aborts a stream and releases its resources.
	TypeReset
	// TypeResponse carries the upstream status and headers (agent -> relay).
	TypeResponse
	// TypeWindow grants more send credit to the peer.
	TypeWindow
)

func (t Type) String() string {
	switch t {
	case TypeOpen:
		return "open"
	case TypeData:
		return "data"
	case TypeEnd:
		return "end"
	case TypeReset:
		return "reset"
	case TypeResponse:
		return "response"
	case TypeWindow:
		return "window"
	default:
		return fmt.Sprintf("type(%d)", byte(t))
	}
}

var (
	// ErrShortFrame means the WebSocket message is smaller than the header.
	ErrShortFrame = errors.New("protocol: short frame")
	// ErrVersion means the peer speaks another protocol version.
	ErrVersion = errors.New("protocol: unsupported version")
	// ErrType means the frame type is unknown.
	ErrType = errors.New("protocol: unknown frame type")
	// ErrPayload means the declared length does not match the message.
	ErrPayload = errors.New("protocol: invalid payload")
)

// Frame is one tunnel frame.
type Frame struct {
	Type    Type
	Stream  uint32
	Payload []byte
}

// Encode serializes the frame. The returned slice is freshly allocated.
func (f Frame) Encode() ([]byte, error) {
	if len(f.Payload) > MaxPayload {
		return nil, fmt.Errorf("%w: %d bytes", ErrPayload, len(f.Payload))
	}
	buf := make([]byte, HeaderSize+len(f.Payload))
	buf[0] = Version
	buf[1] = byte(f.Type)
	binary.BigEndian.PutUint32(buf[2:6], f.Stream)
	binary.BigEndian.PutUint32(buf[6:10], uint32(len(f.Payload)))
	copy(buf[HeaderSize:], f.Payload)
	return buf, nil
}

// Decode parses one frame. The payload aliases b and must be copied if it
// outlives the next read.
func Decode(b []byte) (Frame, error) {
	if len(b) < HeaderSize {
		return Frame{}, ErrShortFrame
	}
	if b[0] != Version {
		return Frame{}, fmt.Errorf("%w: %d", ErrVersion, b[0])
	}
	typ := Type(b[1])
	if typ < TypeOpen || typ > TypeWindow {
		return Frame{}, fmt.Errorf("%w: %d", ErrType, typ)
	}
	stream := binary.BigEndian.Uint32(b[2:6])
	length := int(binary.BigEndian.Uint32(b[6:10]))
	if length > MaxPayload || len(b) != HeaderSize+length {
		return Frame{}, fmt.Errorf("%w: declared %d, got %d", ErrPayload, length, len(b)-HeaderSize)
	}
	return Frame{Type: typ, Stream: stream, Payload: b[HeaderSize:]}, nil
}

// OpenRequest asks the agent to perform one HTTP request against a local
// service. Path includes the query string.
type OpenRequest struct {
	Service string              `json:"service"`
	Method  string              `json:"method"`
	Path    string              `json:"path"`
	Headers map[string][]string `json:"headers,omitempty"`
	Body    bool                `json:"body"`
}

// Response carries the upstream status line and headers.
type Response struct {
	Status  int                 `json:"status"`
	Headers map[string][]string `json:"headers,omitempty"`
}

// Reset explains why a stream was aborted.
type Reset struct {
	Reason string `json:"reason,omitempty"`
}

// Marshal encodes a control payload, enforcing MaxControlPayload.
func Marshal(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	if len(b) > MaxControlPayload {
		return nil, fmt.Errorf("%w: control payload %d bytes", ErrPayload, len(b))
	}
	return b, nil
}

// Unmarshal decodes a control payload.
func Unmarshal(p []byte, v any) error {
	if len(p) > MaxControlPayload {
		return fmt.Errorf("%w: control payload %d bytes", ErrPayload, len(p))
	}
	return json.Unmarshal(p, v)
}

// EncodeWindow serializes a flow-control credit.
func EncodeWindow(n uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, n)
	return b
}

// DecodeWindow parses a flow-control credit.
func DecodeWindow(p []byte) (uint32, error) {
	if len(p) != 4 {
		return 0, fmt.Errorf("%w: window payload %d bytes", ErrPayload, len(p))
	}
	return binary.BigEndian.Uint32(p), nil
}
