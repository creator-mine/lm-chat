package e2e

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type storedIdentity struct {
	PrivateKey string `json:"private_key"`
	PublicKey  string `json:"public_key"`
}

// Identity is the agent's long-term X25519 key pair.
type Identity struct {
	Private []byte
	Public  []byte
}

// PublicKey returns the base64 public key the app pins.
func (i *Identity) PublicKey() string {
	return base64.StdEncoding.EncodeToString(i.Public)
}

// Fingerprint is the grouped SHA-256 of the public key.
func (i *Identity) Fingerprint() string {
	return Fingerprint(i.Public)
}

// Fingerprint returns an uppercase, space-grouped SHA-256 digest.
func Fingerprint(public []byte) string {
	sum := sha256.Sum256(public)
	text := strings.ToUpper(hex.EncodeToString(sum[:]))
	var out strings.Builder
	for i := 0; i < len(text); i += 4 {
		if i > 0 {
			out.WriteByte(' ')
		}
		end := i + 4
		if end > len(text) {
			end = len(text)
		}
		out.WriteString(text[i:end])
	}
	return out.String()
}

// DefaultIdentityPath is used when the agent config has no identity_file.
func DefaultIdentityPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "lm-computer", "relay-identity.json"), nil
}

// LoadOrCreateIdentity reads the identity or generates a new one.
//
// The file is written with mode 0600 and the private key never leaves the
// machine.
func LoadOrCreateIdentity(path string) (*Identity, error) {
	if path == "" {
		defaultPath, err := DefaultIdentityPath()
		if err != nil {
			return nil, err
		}
		path = defaultPath
	}

	data, err := os.ReadFile(path)
	if err == nil {
		var stored storedIdentity
		if err := json.Unmarshal(data, &stored); err != nil {
			return nil, fmt.Errorf("e2e: parse identity: %w", err)
		}
		private, err := base64.StdEncoding.DecodeString(stored.PrivateKey)
		if err != nil || len(private) != PublicKeySize {
			return nil, errors.New("e2e: identity private key is invalid")
		}
		curve := ecdh.X25519()
		key, err := curve.NewPrivateKey(private)
		if err != nil {
			return nil, fmt.Errorf("e2e: identity private key: %w", err)
		}
		public := key.PublicKey().Bytes()
		if stored.PublicKey != "" {
			expected, err := base64.StdEncoding.DecodeString(stored.PublicKey)
			if err != nil || !equal(expected, public) {
				return nil, errors.New("e2e: identity public key does not match the private key")
			}
		}
		return &Identity{Private: private, Public: public}, nil
	}
	if !os.IsNotExist(err) {
		return nil, fmt.Errorf("e2e: read identity: %w", err)
	}

	curve := ecdh.X25519()
	key, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	identity := &Identity{Private: key.Bytes(), Public: key.PublicKey().Bytes()}
	stored := storedIdentity{
		PrivateKey: base64.StdEncoding.EncodeToString(identity.Private),
		PublicKey:  base64.StdEncoding.EncodeToString(identity.Public),
	}
	payload, err := json.MarshalIndent(stored, "", "  ")
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, append(payload, '\n'), 0o600); err != nil {
		return nil, err
	}
	return identity, nil
}

// ParsePublicKey accepts base64 (standard or URL-safe) or 64 hex characters.
func ParsePublicKey(value string) ([]byte, error) {
	compact := strings.TrimSpace(value)
	if compact == "" {
		return nil, errors.New("e2e: empty public key")
	}

	hexCandidate := strings.NewReplacer(":", "", "-", "", " ", "").Replace(compact)
	if len(hexCandidate) == PublicKeySize*2 {
		if decoded, err := hex.DecodeString(hexCandidate); err == nil {
			return validatePublicKey(decoded)
		}
	}

	for _, encoding := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		if decoded, err := encoding.DecodeString(compact); err == nil && len(decoded) == PublicKeySize {
			return validatePublicKey(decoded)
		}
	}
	return nil, errors.New("e2e: public key must be 32 bytes in base64 or hex")
}

func validatePublicKey(public []byte) ([]byte, error) {
	if _, err := ecdh.X25519().NewPublicKey(public); err != nil {
		return nil, fmt.Errorf("e2e: public key: %w", err)
	}
	return public, nil
}

func equal(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
