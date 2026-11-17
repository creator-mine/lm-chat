package protocol

import (
	"bytes"
	"errors"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	cases := []Frame{
		{Type: TypeOpen, Stream: 1, Payload: []byte(`{"service":"plugin"}`)},
		{Type: TypeData, Stream: 42, Payload: bytes.Repeat([]byte("x"), MaxDataPayload)},
		{Type: TypeEnd, Stream: 7},
		{Type: TypeReset, Stream: 9, Payload: []byte(`{"reason":"test"}`)},
	}
	for _, want := range cases {
		encoded, err := want.Encode()
		if err != nil {
			t.Fatalf("encode %s: %v", want.Type, err)
		}
		got, err := Decode(encoded)
		if err != nil {
			t.Fatalf("decode %s: %v", want.Type, err)
		}
		if got.Type != want.Type || got.Stream != want.Stream || !bytes.Equal(got.Payload, want.Payload) {
			t.Fatalf("round trip mismatch: got %+v, want %+v", got, want)
		}
	}
}

func TestDecodeRejectsBrokenFrames(t *testing.T) {
	good, err := (Frame{Type: TypeData, Stream: 1, Payload: []byte("ok")}).Encode()
	if err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name string
		data []byte
		want error
	}{
		{"short", []byte{Version, 1}, ErrShortFrame},
		{"version", append([]byte{Version + 1}, good[1:]...), ErrVersion},
		{"type", append([]byte{Version, 99}, good[2:]...), ErrType},
		{"length", append([]byte{Version, 1, 0, 0, 0, 1, 0, 0, 0, 9}, 'x'), ErrPayload},
	}
	for _, tc := range cases {
		_, decodeErr := Decode(tc.data)
		if !errors.Is(decodeErr, tc.want) {
			t.Fatalf("%s: got %v, want %v", tc.name, decodeErr, tc.want)
		}
	}
}

func TestEncodeRejectsOversizePayload(t *testing.T) {
	_, err := (Frame{Type: TypeData, Payload: make([]byte, MaxPayload+1)}).Encode()
	if !errors.Is(err, ErrPayload) {
		t.Fatalf("got %v, want ErrPayload", err)
	}
}

func TestWindowRoundTrip(t *testing.T) {
	got, err := DecodeWindow(EncodeWindow(12345))
	if err != nil {
		t.Fatal(err)
	}
	if got != 12345 {
		t.Fatalf("got %d, want 12345", got)
	}
	if _, err := DecodeWindow([]byte{1, 2}); !errors.Is(err, ErrPayload) {
		t.Fatalf("short window: got %v", err)
	}
}
