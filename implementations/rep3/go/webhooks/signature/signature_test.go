package signature

import (
	"encoding/hex"
	"testing"
)

const (
	secretText = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
	msgID      = "msg_p5jXN8AQM9LWM0D4loKWxJek"
	msgTS      = "1614265330"
	msgBody    = `{"test": 2432232314}`
	msgSig     = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
)

func mustSecrets(t *testing.T, s string) []Secret {
	t.Helper()
	secrets, err := ParseSecrets([]byte(s))
	if err != nil {
		t.Fatalf("ParseSecrets(%q): %v", s, err)
	}
	return secrets
}

func TestParseSecret(t *testing.T) {
	const want = "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0"
	for _, in := range []string{secretText, "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"} {
		s, err := ParseSecret([]byte(in))
		if err != nil || hex.EncodeToString(s.Raw) != want {
			t.Errorf("ParseSecret(%q) = %x, %v", in, s.Raw, err)
		}
	}
	s, err := ParseSecret([]byte(secretText + "Br"))
	if err != nil || len(s.Raw) != 25 {
		t.Errorf("optional padding: %v %d", err, len(s.Raw))
	}
	// The prefix is removed only once.
	s, err = ParseSecret([]byte("whsec_whsec_AAAA"))
	if err != nil || len(s.Raw) != 3+4 {
		// "whsec_AAAA" is 10 characters -> 7 bytes
		t.Errorf("double prefix: %v %d", err, len(s.Raw))
	}
}

func TestParseSecretInvalid(t *testing.T) {
	long := make([]byte, 513)
	for i := range long {
		long[i] = 'A'
	}
	for _, in := range []string{"", "whsec_", "A", "a b", "a,b", "AB\tC", "é", "whsec_+-ab", string(long)} {
		if _, err := ParseSecret([]byte(in)); err == nil {
			t.Errorf("ParseSecret(%q) accepted", in)
		}
	}
}

func TestParseSecrets(t *testing.T) {
	if got := mustSecrets(t, "AAAA,BBBB,CCCC"); len(got) != 3 {
		t.Fatalf("got %d secrets", len(got))
	}
	for _, in := range []string{"", ",AAAA", "AAAA,", "AAAA,,BBBB", "AAAA,A"} {
		if _, err := ParseSecrets([]byte(in)); err == nil {
			t.Errorf("ParseSecrets(%q) accepted", in)
		}
	}
	sixteen := "AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA,AAAA"
	if got := mustSecrets(t, sixteen); len(got) != 16 {
		t.Fatalf("got %d", len(got))
	}
	if _, err := ParseSecrets([]byte(sixteen + ",AAAA")); err == nil {
		t.Fatal("17 secrets accepted")
	}
}

func TestParseTimestamp(t *testing.T) {
	good := map[string]int64{"0": 0, "5": 5, "-5": -5, "1614265330": 1614265330, "1000000000000000": 1e15, "-1000000000000000": -1e15}
	for in, want := range good {
		if got, ok := ParseTimestamp([]byte(in)); !ok || got != want {
			t.Errorf("ParseTimestamp(%q) = %d, %v", in, got, ok)
		}
	}
	for _, in := range []string{"", "-", "-0", "+5", "007", "00", "1.0", "1e3", "1000000000000001", "99999999999999999999", "5 ", "a"} {
		if _, ok := ParseTimestamp([]byte(in)); ok {
			t.Errorf("ParseTimestamp(%q) accepted", in)
		}
	}
}

func TestSignVector(t *testing.T) {
	got := Sign(mustSecrets(t, secretText), []byte(msgID), []byte(msgTS), []byte(msgBody))
	if string(got) != msgSig {
		t.Fatalf("got %s", got)
	}
}

func TestSignRotation(t *testing.T) {
	s := mustSecrets(t, secretText+",whsec_c2VjcmV0")
	got := string(Sign(s, []byte(msgID), []byte(msgTS), []byte(msgBody)))
	if len(got) != 2*47+1 || got[:47] != msgSig || got[47] != ' ' {
		t.Fatalf("got %q", got)
	}
}

func verify(t *testing.T, secrets, ts string, now int64, header, body string) Result {
	t.Helper()
	return Verify(mustSecrets(t, secrets), []byte(msgID), []byte(ts), now, []byte(header), []byte(body))
}

func TestVerify(t *testing.T) {
	cases := []struct {
		name   string
		ts     string
		now    int64
		header string
		body   string
		wantOK bool
		i, j   int
		reason Reason
	}{
		{"good", msgTS, 1614265400, msgSig, msgBody, true, 0, 0, ""},
		{"exactly 300 old", msgTS, 1614265630, msgSig, msgBody, true, 0, 0, ""},
		{"301 old", msgTS, 1614265631, msgSig, msgBody, false, 0, 0, TimestampTooOld},
		{"exactly 300 new", msgTS, 1614265030, msgSig, msgBody, true, 0, 0, ""},
		{"301 new", msgTS, 1614265029, msgSig, msgBody, false, 0, 0, TimestampTooNew},
		{"wrong body", msgTS, 1614265400, msgSig, "{}", false, 0, 0, NoMatch},
		{"empty header", msgTS, 1614265400, "", msgBody, false, 0, 0, MissingSignature},
		{"only spaces", msgTS, 1614265400, "   ", msgBody, false, 0, 0, MissingSignature},
		{"missing beats timestamp", "x", 0, "", msgBody, false, 0, 0, MissingSignature},
		{"bad timestamp", "0123", 1614265400, msgSig, msgBody, false, 0, 0, InvalidTimestamp},
		{"garbage then good", msgTS, 1614265400, "garbage " + msgSig, msgBody, true, 0, 1, ""},
		{"empty tokens count", msgTS, 1614265400, "  " + msgSig, msgBody, true, 0, 2, ""},
		{"wrong version", msgTS, 1614265400, "v2" + msgSig[2:], msgBody, false, 0, 0, NoMatch},
		{"unpadded value", msgTS, 1614265400, msgSig[:len(msgSig)-1], msgBody, true, 0, 0, ""},
		{"no comma", msgTS, 1614265400, "v1g0hM9SsE", msgBody, false, 0, 0, NoMatch},
	}
	for _, c := range cases {
		got := verify(t, secretText, c.ts, c.now, c.header, c.body)
		if got.OK != c.wantOK || got.Reason != c.reason || (c.wantOK && (got.Secret != c.i || got.Token != c.j)) {
			t.Errorf("%s: got %+v", c.name, got)
		}
	}
}

func TestVerifyRotationOrder(t *testing.T) {
	second := string(Sign(mustSecrets(t, "whsec_c2VjcmV0"), []byte(msgID), []byte(msgTS), []byte(msgBody)))
	got := verify(t, secretText+",whsec_c2VjcmV0", msgTS, 1614265400, second+" "+msgSig, msgBody)
	// Secrets are the outer loop: secret 0 matches header token 1.
	if !got.OK || got.Secret != 0 || got.Token != 1 {
		t.Fatalf("got %+v", got)
	}
	got = verify(t, secretText+",whsec_c2VjcmV0", msgTS, 1614265400, second, msgBody)
	if !got.OK || got.Secret != 1 || got.Token != 0 {
		t.Fatalf("got %+v", got)
	}
}
