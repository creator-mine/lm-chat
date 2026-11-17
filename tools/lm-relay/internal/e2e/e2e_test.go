package e2e

import (
	"bytes"
	"encoding/hex"
	"path/filepath"
	"testing"
)

func testIdentity(t *testing.T) *Identity {
	t.Helper()
	identity, err := LoadOrCreateIdentity(filepath.Join(t.TempDir(), "identity.json"))
	if err != nil {
		t.Fatal(err)
	}
	return identity
}

func TestHandshakeAndBothDirections(t *testing.T) {
	identity := testIdentity(t)
	client, hello, err := NewClient(identity.Public)
	if err != nil {
		t.Fatal(err)
	}
	server, err := NewAgentSession(identity, hello)
	if err != nil {
		t.Fatal(err)
	}

	sealed, err := client.Seal([]byte("request header"))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := server.Open(sealed)
	if err != nil {
		t.Fatal(err)
	}
	if string(plain) != "request header" {
		t.Fatalf("got %q", plain)
	}

	sealed, err = server.Seal([]byte("response header"))
	if err != nil {
		t.Fatal(err)
	}
	plain, err = client.Open(sealed)
	if err != nil {
		t.Fatal(err)
	}
	if string(plain) != "response header" {
		t.Fatalf("got %q", plain)
	}
}

func TestFramesRoundTrip(t *testing.T) {
	identity := testIdentity(t)
	client, hello, err := NewClient(identity.Public)
	if err != nil {
		t.Fatal(err)
	}
	server, err := NewAgentSession(identity, hello)
	if err != nil {
		t.Fatal(err)
	}

	var wire bytes.Buffer
	if err := WriteFrame(&wire, client, []byte("one")); err != nil {
		t.Fatal(err)
	}
	if err := WriteFrame(&wire, client, []byte("two")); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"one", "two"} {
		got, err := ReadFrame(&wire, server)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	}
}

func TestTamperedFrameIsRejected(t *testing.T) {
	identity := testIdentity(t)
	client, hello, err := NewClient(identity.Public)
	if err != nil {
		t.Fatal(err)
	}
	server, err := NewAgentSession(identity, hello)
	if err != nil {
		t.Fatal(err)
	}

	sealed, err := client.Seal([]byte("secret"))
	if err != nil {
		t.Fatal(err)
	}
	sealed[0] ^= 0xff
	if _, err := server.Open(sealed); err == nil {
		t.Fatal("tampered frame was accepted")
	}
}

func TestReplayAndOutOfOrderAreRejected(t *testing.T) {
	identity := testIdentity(t)
	client, hello, err := NewClient(identity.Public)
	if err != nil {
		t.Fatal(err)
	}
	server, err := NewAgentSession(identity, hello)
	if err != nil {
		t.Fatal(err)
	}

	first, err := client.Seal([]byte("first"))
	if err != nil {
		t.Fatal(err)
	}
	second, err := client.Seal([]byte("second"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.Open(second); err == nil {
		t.Fatal("out-of-order frame was accepted")
	}
	if _, err := server.Open(first); err != nil {
		t.Fatal(err)
	}
}

func TestWrongAgentKeyFails(t *testing.T) {
	identity := testIdentity(t)
	other := testIdentity(t)
	client, hello, err := NewClient(identity.Public)
	if err != nil {
		t.Fatal(err)
	}
	wrongServer, err := NewAgentSession(other, hello)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := client.Seal([]byte("secret"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := wrongServer.Open(sealed); err == nil {
		t.Fatal("a different agent key decrypted the frame")
	}
}

func TestParsePublicKeyFormats(t *testing.T) {
	identity := testIdentity(t)
	for _, value := range []string{
		identity.PublicKey(),
		hex.EncodeToString(identity.Public),
	} {
		parsed, err := ParsePublicKey(value)
		if err != nil {
			t.Fatalf("%q: %v", value, err)
		}
		if !bytes.Equal(parsed, identity.Public) {
			t.Fatalf("%q did not round-trip", value)
		}
	}
	if _, err := ParsePublicKey("not a key"); err == nil {
		t.Fatal("garbage key was accepted")
	}
}

func TestIdentityPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identity.json")
	first, err := LoadOrCreateIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	second, err := LoadOrCreateIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.Private, second.Private) || !bytes.Equal(first.Public, second.Public) {
		t.Fatal("identity changed between loads")
	}
}
