package signature_test

import (
	"encoding/hex"
	"errors"
	"testing"

	"example.com/webhooks/hmac"
	"example.com/webhooks/signature"
)

const (
	secretStr = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
	msgID     = "msg_p5jXN8AQM9LWM0D4loKWxJek"
	ts        = "1614265330"
	payload   = `{"test": 2432232314}`
	wantSig   = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
	now       = 1614265330
)

func mustKey(t *testing.T, s string) *hmac.Key {
	t.Helper()
	k, err := signature.ParseSecret(s)
	if err != nil {
		t.Fatalf("ParseSecret(%q): %v", s, err)
	}
	return k
}

func TestParseSecret(t *testing.T) {
	raw, err := signature.DecodeSecret(secretStr)
	if err != nil || hex.EncodeToString(raw) != "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0" {
		t.Fatalf("got %x, %v", raw, err)
	}
	same, _ := signature.DecodeSecret("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
	if string(same) != string(raw) {
		t.Error("prefix should be optional")
	}
	if r, err := signature.DecodeSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr"); err != nil || len(r) != 25 {
		t.Errorf("25-byte secret: %x, %v", r, err)
	}
	// The prefix is removed once only: "whsec_" itself is then Base64 text.
	if r, err := signature.DecodeSecret("whsec_whsec_AAAA"); err != nil || hex.EncodeToString(r) != "c21b1e73f00000" {
		t.Errorf("double prefix decoded to %x, %v", r, err)
	}
	for _, bad := range []string{"", "whsec_", "!!!!", "A", "whsec_A"} {
		if _, err := signature.ParseSecret(bad); !errors.Is(err, signature.ErrInvalidSecret) {
			t.Errorf("ParseSecret(%q) error = %v", bad, err)
		}
	}
}

func TestParseTimestamp(t *testing.T) {
	good := map[string]int64{"0": 0, "5": 5, "-5": -5, "1614265330": 1614265330,
		"1000000000000000": 1e15, "-1000000000000000": -1e15}
	for s, want := range good {
		if got, ok := signature.ParseTimestamp([]byte(s)); !ok || got != want {
			t.Errorf("ParseTimestamp(%q) = %d, %v", s, got, ok)
		}
	}
	for _, s := range []string{"", "-", "-0", "+5", "007", "00", "1.0", "1e3", " 5", "5 ", "1000000000000001", "99999999999999999999", "-a"} {
		if _, ok := signature.ParseTimestamp([]byte(s)); ok {
			t.Errorf("ParseTimestamp(%q) accepted", s)
		}
	}
}

func TestSignPublishedVector(t *testing.T) {
	if got := signature.Sign([]*hmac.Key{mustKey(t, secretStr)}, msgID, ts, []byte(payload)); got != wantSig {
		t.Fatalf("got %s want %s", got, wantSig)
	}
}

func TestSignMultipleSecretsInOrder(t *testing.T) {
	k1, k2 := mustKey(t, secretStr), mustKey(t, "whsec_c2VjcmV0")
	got := signature.Sign([]*hmac.Key{k1, k2}, msgID, ts, []byte(payload))
	want := signature.Sign([]*hmac.Key{k1}, msgID, ts, []byte(payload)) + " " +
		signature.Sign([]*hmac.Key{k2}, msgID, ts, []byte(payload))
	if got != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

func verify(t *testing.T, keys []*hmac.Key, header string, body string, at int64) (signature.Match, error) {
	t.Helper()
	return signature.Verify(keys, msgID, ts, []byte(header), []byte(body), at)
}

func TestVerify(t *testing.T) {
	k := mustKey(t, secretStr)
	other := mustKey(t, "whsec_c2VjcmV0")
	keys := []*hmac.Key{k}

	if m, err := verify(t, keys, wantSig, payload, now+70); err != nil || m != (signature.Match{}) {
		t.Fatalf("basic: %v %v", m, err)
	}
	// Tolerance is inclusive.
	if _, err := verify(t, keys, wantSig, payload, now+300); err != nil {
		t.Errorf("+300: %v", err)
	}
	if _, err := verify(t, keys, wantSig, payload, now-300); err != nil {
		t.Errorf("-300: %v", err)
	}
	if _, err := verify(t, keys, wantSig, payload, now+301); err != signature.ErrTimestampTooOld {
		t.Errorf("+301: %v", err)
	}
	if _, err := verify(t, keys, wantSig, payload, now-301); err != signature.ErrTimestampTooNew {
		t.Errorf("-301: %v", err)
	}
	if _, err := verify(t, keys, wantSig, "{}", now); err != signature.ErrNoMatch {
		t.Errorf("wrong body: %v", err)
	}
	for _, h := range []string{"", " ", "   "} {
		if _, err := verify(t, keys, h, payload, now); err != signature.ErrMissingSignature {
			t.Errorf("header %q: %v", h, err)
		}
	}
	// Garbage tokens are skipped, and empty tokens still count for the index.
	if m, err := verify(t, keys, "garbage  v1,"+wantSig[3:], payload, now); err != nil || m != (signature.Match{0, 2}) {
		t.Errorf("garbage skipped: %v %v", m, err)
	}
	for _, h := range []string{"v2," + wantSig[3:], "v1" + wantSig[3:], "V1," + wantSig[3:], "v1,", "v1,!!"} {
		if _, err := verify(t, keys, h, payload, now); err != signature.ErrNoMatch {
			t.Errorf("header %q: %v", h, err)
		}
	}
	// Rotation: the second secret matches the second token.
	rot := signature.Sign([]*hmac.Key{other, k}, msgID, ts, []byte(payload))
	if m, err := verify(t, []*hmac.Key{k, other}, rot, payload, now); err != nil || m != (signature.Match{0, 1}) {
		t.Errorf("rotation: %v %v", m, err)
	}
	// With several matches, the first (secret, token) in secret-major order wins.
	if m, err := verify(t, []*hmac.Key{other, k}, rot, payload, now); err != nil || m != (signature.Match{0, 0}) {
		t.Errorf("secret order: %v %v", m, err)
	}
}

func TestVerifyTimestampChecksOrder(t *testing.T) {
	keys := []*hmac.Key{mustKey(t, secretStr)}
	// Missing signature outranks a bad timestamp.
	if _, err := signature.Verify(keys, msgID, "bad", nil, nil, now); err != signature.ErrMissingSignature {
		t.Errorf("got %v", err)
	}
	for _, bad := range []string{"bad", "007", "-0", "+1", "1000000000000001"} {
		if _, err := signature.Verify(keys, msgID, bad, []byte("x"), nil, now); err != signature.ErrInvalidTimestamp {
			t.Errorf("ts %q: %v", bad, err)
		}
	}
}

func TestVerifyUsesTimestampTextAsReceived(t *testing.T) {
	keys := []*hmac.Key{mustKey(t, secretStr)}
	sig := signature.Sign(keys, msgID, "-5", []byte("b"))
	if _, err := signature.Verify(keys, msgID, "-5", []byte(sig), []byte("b"), 0); err != nil {
		t.Fatal(err)
	}
}
