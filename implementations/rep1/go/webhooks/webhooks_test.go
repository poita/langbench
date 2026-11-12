package webhooks

import (
	"bytes"
	"encoding/hex"
	"errors"
	"testing"
)

const (
	vecSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
	vecID     = "msg_p5jXN8AQM9LWM0D4loKWxJek"
	vecTS     = "1614265330"
	vecSig    = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
)

var vecBody = []byte(`{"test": 2432232314}`)

func mustKey(t *testing.T, s string) []byte {
	t.Helper()
	k, err := ParseSecret(s)
	if err != nil {
		t.Fatalf("ParseSecret(%q): %v", s, err)
	}
	return k
}

func TestParseSecret(t *testing.T) {
	k := mustKey(t, vecSecret)
	if hex.EncodeToString(k) != "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0" {
		t.Errorf("unexpected key %x", k)
	}
	if !bytes.Equal(k, mustKey(t, "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")) {
		t.Error("prefix should be optional")
	}
	if len(mustKey(t, "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr")) != 25 {
		t.Error("expected 25-byte key")
	}
	// Only one prefix is stripped: the second "whsec_" is Base64 text (6
	// URL-safe characters, so 4 bytes).
	if len(mustKey(t, "whsec_whsec_")) != 4 {
		t.Error("second prefix should be decoded, not stripped")
	}
	for _, bad := range []string{"", "whsec_", "!!!!", "a", "whsec_a", "ab+_"} {
		if _, err := ParseSecret(bad); err == nil {
			t.Errorf("ParseSecret(%q) should fail", bad)
		}
	}
}

func TestParseInt(t *testing.T) {
	good := map[string]int64{"0": 0, "5": 5, "-5": -5, "1000000000000000": 1e15, "-1000000000000000": -1e15}
	for s, want := range good {
		if got, err := ParseInt(s); err != nil || got != want {
			t.Errorf("ParseInt(%q) = %d, %v", s, got, err)
		}
	}
	for _, s := range []string{"", "-", "+5", "007", "-0", "1.0", "1e3", "1000000000000001", "99999999999999999999", " 1", "0x1"} {
		if _, err := ParseInt(s); err == nil {
			t.Errorf("ParseInt(%q) should fail", s)
		}
	}
}

func TestSignVector(t *testing.T) {
	key := mustKey(t, vecSecret)
	if got := Sign(key, vecID, vecTS, vecBody); got != vecSig {
		t.Fatalf("Sign = %q, want %q", got, vecSig)
	}
	hdr := SignHeader([][]byte{key, mustKey(t, "c2VjcmV0")}, vecID, vecTS, vecBody)
	if want := vecSig + " " + Sign(mustKey(t, "c2VjcmV0"), vecID, vecTS, vecBody); hdr != want {
		t.Fatalf("SignHeader = %q, want %q", hdr, want)
	}
}

func TestVerify(t *testing.T) {
	k0 := mustKey(t, vecSecret)
	k1 := mustKey(t, "c2VjcmV0")
	sig1 := Sign(k1, vecID, vecTS, vecBody)
	const now = 1614265330
	tests := []struct {
		name   string
		keys   [][]byte
		header string
		ts     string
		now    int64
		body   []byte
		want   Match
		err    error
	}{
		{"ok", [][]byte{k0}, vecSig, vecTS, now + 70, vecBody, Match{0, 0}, nil},
		{"tolerance inclusive old", [][]byte{k0}, vecSig, vecTS, now + 300, vecBody, Match{0, 0}, nil},
		{"tolerance inclusive new", [][]byte{k0}, vecSig, vecTS, now - 300, vecBody, Match{0, 0}, nil},
		{"too old", [][]byte{k0}, vecSig, vecTS, now + 301, vecBody, Match{}, ErrTimestampTooOld},
		{"too new", [][]byte{k0}, vecSig, vecTS, now - 301, vecBody, Match{}, ErrTimestampTooNew},
		{"empty header", [][]byte{k0}, "", vecTS, now, vecBody, Match{}, ErrMissingSignature},
		{"spaces only", [][]byte{k0}, "   ", vecTS, now, vecBody, Match{}, ErrMissingSignature},
		{"missing beats timestamp", [][]byte{k0}, "", "bad", now, vecBody, Match{}, ErrMissingSignature},
		{"bad timestamp", [][]byte{k0}, vecSig, "0123", now, vecBody, Match{}, ErrInvalidTimestamp},
		{"wrong body", [][]byte{k0}, vecSig, vecTS, now, []byte("{}"), Match{}, ErrNoMatch},
		{"garbage then good", [][]byte{k0}, "garbage " + vecSig, vecTS, now, vecBody, Match{0, 1}, nil},
		{"empty token counts", [][]byte{k0}, "  " + vecSig, vecTS, now, vecBody, Match{0, 2}, nil},
		{"v2 ignored", [][]byte{k0}, "v2," + vecSig[3:], vecTS, now, vecBody, Match{}, ErrNoMatch},
		{"rotation second key", [][]byte{k0, k1}, sig1, vecTS, now, vecBody, Match{1, 0}, nil},
		{"key order wins", [][]byte{k1, k0}, vecSig + " " + sig1, vecTS, now, vecBody, Match{0, 1}, nil},
		{"no comma", [][]byte{k0}, "v1", vecTS, now, vecBody, Match{}, ErrNoMatch},
		{"bad base64 value", [][]byte{k0}, "v1,!!!", vecTS, now, vecBody, Match{}, ErrNoMatch},
	}
	for _, tc := range tests {
		got, err := Verify(tc.keys, vecID, tc.ts, tc.header, tc.body, tc.now)
		if !errors.Is(err, tc.err) || got != tc.want {
			t.Errorf("%s: got %+v, %v; want %+v, %v", tc.name, got, err, tc.want, tc.err)
		}
	}
}
