package protocol_test

import (
	"strings"
	"testing"

	"example.com/webhooks/internal/protocol"
)

func run(in string) []string {
	out := protocol.Run([]byte(in))
	s := strings.TrimSuffix(string(out), "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

func check(t *testing.T, in string, want ...string) {
	t.Helper()
	got := run(in)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("input:\n%s\ngot:\n%s\nwant:\n%s", in, strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

const (
	sec = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
	id  = "msg_p5jXN8AQM9LWM0D4loKWxJek"
	pay = "7b2274657374223a20323433323233323331347d"
	hdr = "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d"
)

func TestSpecWorkedExample(t *testing.T) {
	in := strings.Join([]string{
		"sha256 -", "sha256 616263", "hmac - -", "b64enc 666f6f", "b64urlenc fbff", "b64dec 5a6d3976", "b64dec -",
		"secret " + sec,
		"sign " + sec + " " + id + " 1614265330 " + pay,
		"verify " + sec + " " + id + " 1614265330 1614265400 " + hdr + " " + pay,
		"verify " + sec + " " + id + " 1614265330 1614265631 " + hdr + " " + pay,
		"verify " + sec + " " + id + " 1614265330 1614265400 " + hdr + " 7b7d",
		"verify " + sec + " " + id + " 1614265330 1614265400 - " + pay,
		"sha256 ABCD", "sha256 abc", "frobnicate 1",
	}, "\n")
	check(t, in,
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
		"Zm9v", "-_8", "666f6f", "-",
		"31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0",
		"v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=",
		"ok 0 0", "fail timestamp-too-old", "fail no-match", "fail missing-signature",
		"error", "error", "error")
}

func TestLineHandling(t *testing.T) {
	check(t, "\n   \nsha256 -\n\n", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	check(t, "sha256 616263", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") // no trailing LF
	check(t, "sha256  616263\n sha256 616263\nsha256 616263 \nsha256\tabc\nsha256 61 62\n", "error", "error", "error", "error", "error")
	check(t, "b64enc \nb64dec 6\nb64dec zz\nb64dec 41\n", "error", "error", "error", "error")
	check(t, "sha256 616263\r\n", "error")
}

func TestCommandErrors(t *testing.T) {
	check(t, strings.Join([]string{
		"secret whsec_", "secret a,b", "secret " + strings.Repeat("A", 513), "secret A",
		"sign " + sec + " " + id + " 007 -", // non-canonical ts
		"sign " + sec + "," + " " + id + " 1 -",
		"sign bad!! " + id + " 1 -",
		"sign " + sec + " " + strings.Repeat("a", 257) + " 1 -",
		"verify " + sec + " " + id + " 007 1 - -",
		"verify " + sec + " " + id + " 1 007 - -",
		"verify " + sec + " " + id + " " + strings.Repeat("1", 65) + " 1 - -",
		"b64dec 5a6d3976 extra",
	}, "\n"), "error", "error", "error", "error", "error", "error", "error", "error", "fail missing-signature", "error", "error", "error")
}

func TestVerifyNonCanonicalTimestampIsFailNotError(t *testing.T) {
	check(t, "verify "+sec+" "+id+" 007 1 "+hdr+" "+pay, "fail invalid-timestamp")
	check(t, "verify "+sec+" "+id+" 1 1 - "+pay, "fail missing-signature")
}

func TestSecretsList(t *testing.T) {
	two := sec + ",whsec_c2VjcmV0"
	got := run("sign " + two + " " + id + " 1614265330 " + pay)
	if len(got) != 1 || strings.Count(got[0], " ") != 1 || !strings.HasPrefix(got[0], "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE= v1,") {
		t.Fatalf("got %v", got)
	}
	sixteen := strings.TrimSuffix(strings.Repeat("c2VjcmV0,", 16), ",")
	if got := run("sign " + sixteen + " a 1 -"); len(got) != 1 || strings.Count(got[0], " ") != 15 {
		t.Errorf("16 secrets: %v", got)
	}
	check(t, "sign "+sixteen+",c2VjcmV0 a 1 -", "error")
	check(t, "sign "+sec+",,"+sec+" a 1 -", "error")
}

func TestSimulateBlock(t *testing.T) {
	in := `simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200
event msg_1 1700000000 user.created 7b7d

event msg_2 1700000100 repo.pushed 7b7d
end
`
	check(t, in,
		"sim 5 3",
		"attempt 1 msg_1 ep_a 1 1700000000 failure 500",
		"attempt 2 msg_1 ep_b 1 1700000000 success 200",
		"attempt 3 msg_1 ep_a 2 1700000005 timeout -",
		"attempt 4 msg_2 ep_a 1 1700000100 success 200",
		"attempt 5 msg_1 ep_a 3 1700000305 success 200",
		"delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94=",
		"delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s=",
		"delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U=",
	)
}

func TestSimulateBlockErrors(t *testing.T) {
	ep := "endpoint a c2VjcmV0 * 200\n"
	ev := "event e1 0 t 7b7d\n"
	bad := map[string]string{
		"no endpoint":       "simulate\nend\n",
		"endpoint after":    "simulate\n" + ep + ev + "endpoint b c2VjcmV0 * 200\nend\n",
		"dup endpoint":      "simulate\n" + ep + ep + "end\n",
		"dup event":         "simulate\n" + ep + ev + ev + "end\n",
		"nested simulate":   "simulate\n" + ep + "simulate\nend\n",
		"unknown":           "simulate\n" + ep + "bogus x\nend\n",
		"bad filter":        "simulate\nendpoint a c2VjcmV0 t,,u 200\nend\n",
		"bad script":        "simulate\nendpoint a c2VjcmV0 * 99\nend\n",
		"bad script word":   "simulate\nendpoint a c2VjcmV0 * Timeout\nend\n",
		"bad ts":            "simulate\n" + ep + "event e1 01 t 7b7d\nend\n",
		"bad id":            "simulate\nendpoint a/b c2VjcmV0 * 200\nend\n",
		"double space":      "simulate\nendpoint a  c2VjcmV0 * 200\nend\n",
		"end with space":    "simulate\n" + ep + "end \n",
		"not terminated":    "simulate\n" + ep + ev,
		"too many fields":   "simulate\nendpoint a c2VjcmV0 * 200 x\nend\n",
		"bad secret":        "simulate\nendpoint a !! * 200\nend\n",
		"17 filter entries": "simulate\nendpoint a c2VjcmV0 " + strings.TrimSuffix(strings.Repeat("t,", 17), ",") + " 200\nend\n",
		"65 script entries": "simulate\nendpoint a c2VjcmV0 * " + strings.TrimSuffix(strings.Repeat("200,", 65), ",") + "\nend\n",
	}
	for name, in := range bad {
		if got := run(in); len(got) != 1 || got[0] != "error" {
			t.Errorf("%s: got %v", name, got)
		}
	}
	// A bad block resumes normal parsing after its "end".
	check(t, "simulate\nbogus\nsha256 -\nend\nsha256 -\n", "error", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	// "simulate now" does not open a block.
	check(t, "simulate now\nend\n", "error", "error")
}

func TestSimulateLimits(t *testing.T) {
	var b strings.Builder
	b.WriteString("simulate\n")
	for i := 0; i < 64; i++ {
		b.WriteString("endpoint e" + strings.Repeat("x", i) + " c2VjcmV0 * 200\n")
	}
	if got := run(b.String() + "end\n"); got[0] != "sim 0 0" {
		t.Errorf("64 endpoints: %v", got[0])
	}
	b.WriteString("endpoint last c2VjcmV0 * 200\nend\n")
	if got := run(b.String()); got[0] != "error" {
		t.Errorf("65 endpoints: %v", got[0])
	}
}
