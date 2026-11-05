package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func run(in string) string { return string(Run([]byte(in))) }

func TestSimpleCommands(t *testing.T) {
	in := `sha256 -
sha256 616263
hmac - -
b64enc 666f6f
b64enc -
b64urlenc fbff
b64dec 5a6d3976
b64dec -
secret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw
sha256 ABCD
sha256 abc
frobnicate 1
`
	want := `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad
Zm9v
-
-_8
666f6f
-
31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0
error
error
error
`
	if got := run(in); got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestSignVerify(t *testing.T) {
	const s = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw msg_p5jXN8AQM9LWM0D4loKWxJek 1614265330"
	const P = "7b2274657374223a20323433323233323331347d"
	const H = "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d"
	in := "sign " + s + " " + P + "\n" +
		"verify " + s + " 1614265400 " + H + " " + P + "\n" +
		"verify " + s + " 1614265631 " + H + " " + P + "\n" +
		"verify " + s + " 1614265400 " + H + " 7b7d\n" +
		"verify " + s + " 1614265400 - " + P + "\n" +
		"verify " + strings.Replace(s, "1614265330", "01614265330", 1) + " 1614265400 " + H + " " + P + "\n" +
		"sign " + strings.Replace(s, "1614265330", "01614265330", 1) + " " + P + "\n" +
		"verify " + s + " 01 " + H + " " + P + "\n"
	want := "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=\nok 0 0\nfail timestamp-too-old\nfail no-match\nfail missing-signature\nfail invalid-timestamp\nerror\nerror\n"
	// Line 6 receives a non-canonical timestamp: data, not a syntax error.
	if got := run(in); got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestVerifyNonCanonicalTimestamp(t *testing.T) {
	// The header check comes before the timestamp check.
	got := run("verify AAAA id 007 100 61 -\nverify AAAA id 007 100 - -\n")
	if got != "fail invalid-timestamp\nfail missing-signature\n" {
		t.Fatalf("got %q", got)
	}
}

func TestLineHandling(t *testing.T) {
	cases := map[string]string{
		"":                    "",
		"\n  \n\n":            "",
		"sha256 -":            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n",
		"sha256  -\n":         "error\n",
		" sha256 -\n":         "error\n",
		"sha256 - \n":         "error\n",
		"sha256\t- \n":        "error\n",
		"sha256\n":            "error\n",
		"sha256 - -\n":        "error\n",
		"b64dec 5a6d 39\n":    "error\n",
		"b64dec 20\n":         "error\n", // a lone space is not Base64
		"secret a,b\n":        "error\n",
		"simulate now\nend\n": "error\nerror\n",
		"endpoint\nevent\n":   "error\nerror\n",
	}
	for in, want := range cases {
		if got := run(in); got != want {
			t.Errorf("run(%q) = %q, want %q", in, got, want)
		}
	}
}

const ep = "endpoint e whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 200\n"

func TestSimulateBlocks(t *testing.T) {
	ok := "sim 1 1\nattempt 1 m e 1 5 success 200\n"
	cases := []struct{ in, want string }{
		{"simulate\n" + ep + "\nevent m 5 t -\n   \nend\n", ok + "delivery m e delivered 1 5 " + sig + "\n"},
		{"simulate\n" + ep + "end\n", "sim 0 0\n"},
		{"simulate\nend\n", "error\n"},
		{"simulate\n" + ep, "error\n"},                                    // no end
		{"simulate\n" + ep + "bogus\nend\nsha256 -\n", "error\n" + empty}, // bad block, then carries on
		{"simulate\n" + ep + "event m 5 t -\n" + ep + "end\nsha256 -\n", "error\n" + empty},
		{"simulate\n" + ep + "simulate\nend\n", "error\n"},
		{"simulate\n" + ep + "end \nend\n", "error\n"},
		{"simulate\n" + ep + "event m 5 t -\nevent m 6 t -\nend\n", "error\n"},
	}
	for _, c := range cases {
		if got := run(c.in); got != c.want {
			t.Errorf("run(%q)\n got %q\nwant %q", c.in, got, c.want)
		}
	}
}

const empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"

var sig = func() string {
	out := run("sign whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw m 5 -")
	return strings.TrimSpace(out)
}()

func TestLongLine(t *testing.T) {
	payload := strings.Repeat("ab", 32768)
	out := run("sha256 " + payload + "\n")
	if len(out) != 65 {
		t.Fatalf("got %q", out)
	}
}

// TestExamples replays the repository's example tests when they are present.
func TestExamples(t *testing.T) {
	files, _ := filepath.Glob("../../../problems/webhooks/tests/*.in")
	if len(files) == 0 {
		t.Skip("problem tests not found")
	}
	for _, in := range files {
		input, err := os.ReadFile(in)
		if err != nil {
			t.Fatal(err)
		}
		want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.TrimRight(string(Run(input)), "\n"); got != strings.TrimRight(string(want), "\n") {
			t.Errorf("%s: output differs", filepath.Base(in))
		}
	}
}
