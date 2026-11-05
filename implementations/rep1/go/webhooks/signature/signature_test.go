package signature_test

import (
	"encoding/hex"
	"errors"
	"strings"
	"testing"

	"example.com/webhooks/signature"
)

const (
	secretStr = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
	msgID     = "msg_p5jXN8AQM9LWM0D4loKWxJek"
	ts        = "1614265330"
	goodSig   = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
)

var body = []byte(`{"test": 2432232314}`)

func mustSecret(t *testing.T, s string) *signature.Secret {
	t.Helper()
	sec, err := signature.ParseSecret(s)
	if err != nil {
		t.Fatalf("ParseSecret(%q): %v", s, err)
	}
	return sec
}

func TestParseSecret(t *testing.T) {
	const want = "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0"
	for _, s := range []string{secretStr, "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"} {
		if got := hex.EncodeToString(mustSecret(t, s).Key()); got != want {
			t.Errorf("%q -> %s", s, got)
		}
	}
	if got := len(mustSecret(t, secretStr+"Br").Key()); got != 25 {
		t.Errorf("padded-less secret has %d bytes", got)
	}
	// The prefix is removed once: the second "whsec_" is Base64 data (6
	// characters, URL-safe alphabet) and decodes to 4 bytes.
	if got := hex.EncodeToString(mustSecret(t, "whsec_whsec_").Key()); got != "c21b1e73" {
		t.Errorf("double prefix key = %s", got)
	}
	for _, bad := range []string{"", "whsec_", "A", "not base64!", "Zm9v=="} {
		if _, err := signature.ParseSecret(bad); !errors.Is(err, signature.ErrInvalidSecret) {
			t.Errorf("ParseSecret(%q) err = %v", bad, err)
		}
	}
	if _, err := signature.NewSecret(nil); err == nil {
		t.Error("empty raw key accepted")
	}
}

func TestSignVector(t *testing.T) {
	got := signature.Sign([]*signature.Secret{mustSecret(t, secretStr)}, msgID, ts, body)
	if got != goodSig {
		t.Fatalf("got %q", got)
	}
}

func TestSignMultipleSecrets(t *testing.T) {
	a, b := mustSecret(t, secretStr), mustSecret(t, "whsec_c2VjcmV0")
	got := signature.Sign([]*signature.Secret{a, b}, msgID, ts, body)
	want := goodSig + " " + signature.Sign([]*signature.Secret{b}, msgID, ts, body)
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestParseTimestamp(t *testing.T) {
	good := map[string]int64{"0": 0, "5": 5, "-5": -5, "1614265330": 1614265330, "1000000000000000": 1e15, "-1000000000000000": -1e15}
	for s, want := range good {
		if got, ok := signature.ParseTimestamp(s); !ok || got != want {
			t.Errorf("ParseTimestamp(%q) = %d, %v", s, got, ok)
		}
	}
	for _, s := range []string{"", "-", "-0", "+5", "007", "00", "1.0", "1e3", " 1", "1 ", "1000000000000001", "99999999999999999999", "0x1"} {
		if _, ok := signature.ParseTimestamp(s); ok {
			t.Errorf("ParseTimestamp(%q) should fail", s)
		}
	}
}

func TestVerify(t *testing.T) {
	sec := mustSecret(t, secretStr)
	other := mustSecret(t, "whsec_c2VjcmV0")
	otherSig := signature.Sign([]*signature.Secret{other}, msgID, ts, body)
	now := int64(1614265400)

	tests := []struct {
		name    string
		secrets []*signature.Secret
		ts      string
		header  string
		body    []byte
		now     int64
		want    signature.Match
		reason  signature.Reason
	}{
		{"ok", []*signature.Secret{sec}, ts, goodSig, body, now, signature.Match{0, 0}, ""},
		{"exactly at tolerance old", []*signature.Secret{sec}, ts, goodSig, body, 1614265630, signature.Match{0, 0}, ""},
		{"too old", []*signature.Secret{sec}, ts, goodSig, body, 1614265631, signature.Match{}, signature.TimestampTooOld},
		{"exactly at tolerance new", []*signature.Secret{sec}, ts, goodSig, body, 1614265030, signature.Match{0, 0}, ""},
		{"too new", []*signature.Secret{sec}, ts, goodSig, body, 1614265029, signature.Match{}, signature.TimestampTooNew},
		{"empty header", []*signature.Secret{sec}, ts, "", body, now, signature.Match{}, signature.MissingSignature},
		{"spaces-only header", []*signature.Secret{sec}, ts, "   ", body, now, signature.Match{}, signature.MissingSignature},
		{"missing beats bad timestamp", []*signature.Secret{sec}, "x", "", body, now, signature.Match{}, signature.MissingSignature},
		{"bad timestamp", []*signature.Secret{sec}, "01", goodSig, body, now, signature.Match{}, signature.InvalidTimestamp},
		{"bad timestamp beats stale", []*signature.Secret{sec}, "+5", goodSig, body, now, signature.Match{}, signature.InvalidTimestamp},
		{"wrong body", []*signature.Secret{sec}, ts, goodSig, []byte("{}"), now, signature.Match{}, signature.NoMatch},
		{"garbage first", []*signature.Secret{sec}, ts, "garbage " + goodSig, body, now, signature.Match{0, 1}, ""},
		{"empty tokens counted", []*signature.Secret{sec}, ts, "  " + goodSig, body, now, signature.Match{0, 2}, ""},
		{"wrong version", []*signature.Secret{sec}, ts, "v2" + goodSig[2:], body, now, signature.Match{}, signature.NoMatch},
		{"no comma", []*signature.Secret{sec}, ts, "v1", body, now, signature.Match{}, signature.NoMatch},
		{"bad base64", []*signature.Secret{sec}, ts, "v1,!!!", body, now, signature.Match{}, signature.NoMatch},
		{"second secret", []*signature.Secret{sec, other}, ts, otherSig, body, now, signature.Match{1, 0}, ""},
		{"secret order wins over token order", []*signature.Secret{other, sec}, ts, goodSig + " " + otherSig, body, now, signature.Match{0, 1}, ""},
		{"truncated mac", []*signature.Secret{sec}, ts, goodSig[:len(goodSig)-4] + "=", body, now, signature.Match{}, signature.NoMatch},
		{"url-safe base64 accepted", []*signature.Secret{sec}, ts, "v1," + urlSafe(t, goodSig[3:]), body, now, signature.Match{0, 0}, ""},
	}
	for _, tc := range tests {
		got, err := signature.Verify(tc.secrets, msgID, tc.ts, tc.header, tc.body, tc.now)
		if tc.reason != "" {
			if !errors.Is(err, tc.reason) {
				t.Errorf("%s: err = %v, want %s", tc.name, err, tc.reason)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("%s: got %+v, %v; want %+v", tc.name, got, err, tc.want)
		}
	}
}

// urlSafe rewrites a standard-alphabet string into the URL-safe alphabet.
func urlSafe(t *testing.T, s string) string {
	t.Helper()
	return strings.NewReplacer("+", "-", "/", "_").Replace(s)
}
