package commands_test

import (
	"bytes"
	"strings"
	"testing"

	"example.com/webhooks/commands"
)

func run(in string) string { return string(commands.Execute([]byte(in), nil)) }

func TestSpecExamples(t *testing.T) {
	const (
		secret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
		id     = "msg_p5jXN8AQM9LWM0D4loKWxJek"
		p      = "7b2274657374223a20323433323233323331347d"
		h      = "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d"
	)
	in := strings.Join([]string{
		"sha256 -", "sha256 616263", "hmac - -", "b64enc 666f6f", "b64urlenc fbff",
		"b64dec 5a6d3976", "b64dec -", "secret " + secret,
		"sign " + secret + " " + id + " 1614265330 " + p,
		"verify " + secret + " " + id + " 1614265330 1614265400 " + h + " " + p,
		"verify " + secret + " " + id + " 1614265330 1614265631 " + h + " " + p,
		"verify " + secret + " " + id + " 1614265330 1614265400 " + h + " 7b7d",
		"verify " + secret + " " + id + " 1614265330 1614265400 - " + p,
		"sha256 ABCD", "sha256 abc", "frobnicate 1",
	}, "\n")
	want := strings.Join([]string{
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
		"Zm9v", "-_8", "666f6f", "-",
		"31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0",
		"v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=",
		"ok 0 0", "fail timestamp-too-old", "fail no-match", "fail missing-signature",
		"error", "error", "error", "",
	}, "\n")
	if got := run(in); got != want { // input has no trailing newline; output always does
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestErrors(t *testing.T) {
	bad := []string{
		"sha256", "sha256 00 00", "sha256  00", " sha256 00", "sha256 00 ", "sha256\t00",
		"sha256 0", "sha256 0G", "SHA256 00", "b64dec 41", "b64dec 5a6d3976 ", "secret ",
		"secret whsec_", "secret a,b", "secret " + strings.Repeat("A", 513),
		"sign a id 1 -", "sign c2VjcmV0 id 01 -", "sign c2VjcmV0 id 1", "sign c2VjcmV0, id 1 -",
		"sign " + strings.TrimSuffix(strings.Repeat("c2VjcmV0,", 17), ",") + " id 1 -",
		"verify c2VjcmV0 id x now - -", "verify c2VjcmV0 id 1 +5 - -",
		"verify c2VjcmV0 id " + strings.Repeat("1", 65) + " 5 - -",
		"simulate now", "end", "endpoint a b c d", "event a 1 t -",
	}
	for _, l := range bad {
		if got := run(l + "\n"); got != "error\n" {
			t.Errorf("%q -> %q, want error", l, got)
		}
	}
}

func TestBlankLinesIgnoredAndNoTrailingNewline(t *testing.T) {
	if got := run("\n   \nsha256 -\n\n  \n"); got != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n" {
		t.Errorf("got %q", got)
	}
	if got := run("b64enc 61"); got != "YQ==\n" {
		t.Errorf("got %q", got)
	}
}

func TestVerifyNonCanonicalTimestampIsAFailureNotAnError(t *testing.T) {
	if got := run("verify c2VjcmV0 id 007 5 76312c41 -\n"); got != "fail invalid-timestamp\n" {
		t.Errorf("got %q", got)
	}
}

const simExample = `simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200
event msg_1 1700000000 user.created 7b7d
event msg_2 1700000100 repo.pushed 7b7d
end
`

func TestSimulateExample(t *testing.T) {
	want := `sim 5 3
attempt 1 msg_1 ep_a 1 1700000000 failure 500
attempt 2 msg_1 ep_b 1 1700000000 success 200
attempt 3 msg_1 ep_a 2 1700000005 timeout -
attempt 4 msg_2 ep_a 1 1700000100 success 200
attempt 5 msg_1 ep_a 3 1700000305 success 200
delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=
delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s=
delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U=
`
	if got := run(simExample); got != want {
		t.Errorf("got:\n%s", got)
	}
}

func TestSimulateEmptyEventList(t *testing.T) {
	if got := run("simulate\nendpoint a c2VjcmV0 * 200\n\nend\n"); got != "sim 0 0\n" {
		t.Errorf("got %q", got)
	}
}

func TestSimulateBlockErrors(t *testing.T) {
	const ep = "endpoint a c2VjcmV0 * 200\n"
	tests := map[string]string{
		"no endpoints":          "simulate\nend\n",
		"duplicate endpoint":    "simulate\n" + ep + ep + "end\n",
		"duplicate event":       "simulate\n" + ep + "event e 1 t -\nevent e 2 t -\nend\n",
		"endpoint after event":  "simulate\n" + ep + "event e 1 t -\n" + "endpoint b c2VjcmV0 * 200\nend\n",
		"nested simulate":       "simulate\n" + ep + "simulate\nend\n",
		"bad status":            "simulate\nendpoint a c2VjcmV0 * 99\nend\n",
		"bad status 600":        "simulate\nendpoint a c2VjcmV0 * 600\nend\n",
		"bad status 0200":       "simulate\nendpoint a c2VjcmV0 * 0200\nend\n",
		"bad filter":            "simulate\nendpoint a c2VjcmV0 *,x 200\nend\n",
		"bad ts":                "simulate\n" + ep + "event e 01 t -\nend\n",
		"bad payload":           "simulate\n" + ep + "event e 1 t ZZ\nend\n",
		"bad id":                "simulate\nendpoint a/b c2VjcmV0 * 200\nend\n",
		"unterminated":          "simulate\n" + ep + "event e 1 t -\n",
		"end with space":        "simulate\n" + ep + "end \n",
		"too many filter types": "simulate\nendpoint a c2VjcmV0 " + strings.TrimSuffix(strings.Repeat("t,", 17), ",") + " 200\nend\n",
		"too many responses":    "simulate\nendpoint a c2VjcmV0 * " + strings.TrimSuffix(strings.Repeat("200,", 65), ",") + "\nend\n",
	}
	const next = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"
	for name, in := range tests {
		// Every malformed block prints one "error" and the reader resumes
		// after its "end"; a block that never ends swallows the rest.
		want := "error\n" + next
		if name == "unterminated" || name == "end with space" {
			want = "error\n"
		}
		if got := run(in + "sha256 -\n"); got != want {
			t.Errorf("%s: got %q, want %q", name, got, want)
		}
	}
}

func TestSimulateLimits(t *testing.T) {
	var b strings.Builder
	b.WriteString("simulate\n")
	for i := 0; i < 64; i++ {
		b.WriteString("endpoint e" + string(rune('A'+i/26)) + string(rune('a'+i%26)) + " c2VjcmV0 * 200\n")
	}
	ok := b.String() + "end\n"
	if got := run(ok); !strings.HasPrefix(got, "sim 0 0") {
		t.Errorf("64 endpoints: %q", got)
	}
	over := b.String() + "endpoint extra c2VjcmV0 * 200\nend\n"
	if got := run(over); got != "error\n" {
		t.Errorf("65 endpoints: %q", got)
	}
}

func TestLongLine(t *testing.T) {
	payload := strings.Repeat("ab", 70000)
	out := run("sha256 " + payload + "\n")
	if len(out) != 65 {
		t.Fatalf("got %q", out)
	}
}

func TestRunReaderWriter(t *testing.T) {
	var out bytes.Buffer
	if err := commands.Run(strings.NewReader("sha256 616263\n"), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n" {
		t.Errorf("got %q", out.String())
	}
}
