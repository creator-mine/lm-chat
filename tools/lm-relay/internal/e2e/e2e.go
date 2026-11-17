// Package e2e implements the optional end-to-end encryption layer between the
// app and the relay agent.
//
// The relay only sees opaque frames. The app pins the agent's X25519 public
// key, so a compromised relay cannot substitute its own key.
package e2e

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const (
	// Magic prefixes the hello message and the AEAD associated data.
	Magic = "LME2E1"
	// Version is the current wire version.
	Version byte = 1
	// PublicKeySize is an X25519 public key.
	PublicKeySize = 32
	// SaltSize is the HKDF salt chosen by the app.
	SaltSize = 16
	// HelloSize is magic + version + app public key + salt.
	HelloSize = len(Magic) + 1 + PublicKeySize + SaltSize
	// MaxPlaintext is the largest plaintext frame.
	MaxPlaintext = 32 << 10
	// MaxFrame bounds one ciphertext frame (plaintext + 16-byte tag).
	MaxFrame = MaxPlaintext + 16
)

const (
	directionClient = 'c'
	directionAgent  = 'a'
)

// Session encrypts and decrypts one direction of one request.
type Session struct {
	read       cipher.AEAD
	write      cipher.AEAD
	readDir    byte
	writeDir   byte
	readCount  uint64
	writeCount uint64
}

// Request is the encrypted request header. It mirrors the fields the relay
// would otherwise route by.
type Request struct {
	Service string              `json:"service"`
	Method  string              `json:"method"`
	Path    string              `json:"path"`
	Headers map[string][]string `json:"headers,omitempty"`
	Body    bool                `json:"body"`
}

// Response is the encrypted response status and headers.
type Response struct {
	Status  int                 `json:"status"`
	Headers map[string][]string `json:"headers,omitempty"`
}

// BuildHello serializes the first plaintext message.
func BuildHello(appPublic, salt []byte) []byte {
	out := make([]byte, 0, HelloSize)
	out = append(out, Magic...)
	out = append(out, Version)
	out = append(out, appPublic...)
	out = append(out, salt...)
	return out
}

// ParseHello reads and validates the first plaintext message.
func ParseHello(hello []byte) (appPublic, salt []byte, err error) {
	if len(hello) != HelloSize {
		return nil, nil, fmt.Errorf("e2e: hello is %d bytes, want %d", len(hello), HelloSize)
	}
	if string(hello[:len(Magic)]) != Magic {
		return nil, nil, errors.New("e2e: bad magic")
	}
	if hello[len(Magic)] != Version {
		return nil, nil, fmt.Errorf("e2e: unsupported version %d", hello[len(Magic)])
	}
	offset := len(Magic) + 1
	return append([]byte(nil), hello[offset:offset+PublicKeySize]...),
		append([]byte(nil), hello[offset+PublicKeySize:]...), nil
}

// NewClient starts a handshake against a pinned agent key.
func NewClient(agentPublic []byte) (*Session, []byte, error) {
	curve := ecdh.X25519()
	peer, err := curve.NewPublicKey(agentPublic)
	if err != nil {
		return nil, nil, fmt.Errorf("e2e: agent public key: %w", err)
	}
	ephemeral, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	shared, err := ephemeral.ECDH(peer)
	if err != nil {
		return nil, nil, err
	}
	salt := make([]byte, SaltSize)
	if _, err := rand.Read(salt); err != nil {
		return nil, nil, err
	}
	appPublic := ephemeral.PublicKey().Bytes()
	c2a, a2c := deriveKeys(shared, salt, appPublic, agentPublic)
	session, err := newSession(c2a, a2c, true)
	if err != nil {
		return nil, nil, err
	}
	return session, BuildHello(appPublic, salt), nil
}

// NewAgentSession answers a client hello with the agent identity.
func NewAgentSession(identity *Identity, hello []byte) (*Session, error) {
	appPublic, salt, err := ParseHello(hello)
	if err != nil {
		return nil, err
	}
	curve := ecdh.X25519()
	private, err := curve.NewPrivateKey(identity.Private)
	if err != nil {
		return nil, fmt.Errorf("e2e: identity: %w", err)
	}
	peer, err := curve.NewPublicKey(appPublic)
	if err != nil {
		return nil, fmt.Errorf("e2e: client public key: %w", err)
	}
	shared, err := private.ECDH(peer)
	if err != nil {
		return nil, err
	}
	c2a, a2c := deriveKeys(shared, salt, appPublic, identity.Public)
	return newSession(c2a, a2c, false)
}

func newSession(c2a, a2c []byte, client bool) (*Session, error) {
	readKey, writeKey := a2c, c2a
	readDir, writeDir := byte(directionAgent), byte(directionClient)
	if !client {
		readKey, writeKey = c2a, a2c
		readDir, writeDir = directionClient, directionAgent
	}
	read, err := newAEAD(readKey)
	if err != nil {
		return nil, err
	}
	write, err := newAEAD(writeKey)
	if err != nil {
		return nil, err
	}
	return &Session{read: read, write: write, readDir: readDir, writeDir: writeDir}, nil
}

func newAEAD(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// Seal encrypts one frame.
func (s *Session) Seal(plain []byte) ([]byte, error) {
	if len(plain) > MaxPlaintext {
		return nil, fmt.Errorf("e2e: plaintext frame is %d bytes", len(plain))
	}
	nonce := nonceFor(s.writeCount)
	aad := aadFor(s.writeDir, s.writeCount)
	sealed := s.write.Seal(nil, nonce, plain, aad)
	s.writeCount++
	return sealed, nil
}

// Open decrypts one frame.
func (s *Session) Open(sealed []byte) ([]byte, error) {
	if len(sealed) > MaxFrame || len(sealed) < s.read.Overhead() {
		return nil, fmt.Errorf("e2e: ciphertext frame is %d bytes", len(sealed))
	}
	nonce := nonceFor(s.readCount)
	aad := aadFor(s.readDir, s.readCount)
	plain, err := s.read.Open(nil, nonce, sealed, aad)
	if err != nil {
		return nil, errors.New("e2e: authentication failed")
	}
	s.readCount++
	return plain, nil
}

// WriteFrame writes one length-prefixed encrypted frame.
func WriteFrame(w io.Writer, session *Session, plain []byte) error {
	sealed, err := session.Seal(plain)
	if err != nil {
		return err
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(sealed)))
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	_, err = w.Write(sealed)
	return err
}

// ReadFrame reads one length-prefixed encrypted frame.
func ReadFrame(r io.Reader, session *Session) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(header[:])
	if length == 0 || length > MaxFrame {
		return nil, fmt.Errorf("e2e: frame length %d", length)
	}
	sealed := make([]byte, length)
	if _, err := io.ReadFull(r, sealed); err != nil {
		return nil, err
	}
	return session.Open(sealed)
}

// BodyReader decrypts request body frames on demand.
type BodyReader struct {
	reader  io.Reader
	session *Session
	pending []byte
}

// NewBodyReader wraps an encrypted stream.
func NewBodyReader(r io.Reader, session *Session) *BodyReader {
	return &BodyReader{reader: r, session: session}
}

func (b *BodyReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for len(b.pending) == 0 {
		frame, err := ReadFrame(b.reader, b.session)
		if err != nil {
			return 0, err
		}
		b.pending = frame
	}
	n := copy(p, b.pending)
	b.pending = b.pending[n:]
	return n, nil
}

func deriveKeys(shared, salt, appPublic, agentPublic []byte) (c2a, a2c []byte) {
	prk := hkdfExtract(salt, shared)
	c2a = hkdfExpand(prk, append(append([]byte(Magic+" c2a"), appPublic...), agentPublic...))
	a2c = hkdfExpand(prk, append(append([]byte(Magic+" a2c"), appPublic...), agentPublic...))
	return c2a, a2c
}

func hkdfExtract(salt, input []byte) []byte {
	if len(salt) == 0 {
		salt = make([]byte, sha256.Size)
	}
	mac := hmac.New(sha256.New, salt)
	mac.Write(input)
	return mac.Sum(nil)
}

func hkdfExpand(prk, info []byte) []byte {
	mac := hmac.New(sha256.New, prk)
	mac.Write(info)
	mac.Write([]byte{1})
	return mac.Sum(nil)
}

func nonceFor(counter uint64) []byte {
	nonce := make([]byte, 12)
	binary.BigEndian.PutUint64(nonce[4:], counter)
	return nonce
}

func aadFor(direction byte, counter uint64) []byte {
	aad := make([]byte, 0, len(Magic)+1+1+8)
	aad = append(aad, Magic...)
	aad = append(aad, Version, direction)
	var tail [8]byte
	binary.BigEndian.PutUint64(tail[:], counter)
	aad = append(aad, tail[:]...)
	return aad
}
