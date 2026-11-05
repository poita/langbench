package sim

import (
	"strings"
	"testing"
)

func f(s string) [][]byte {
	var out [][]byte
	for _, x := range strings.Split(s, " ") {
		out = append(out, []byte(x))
	}
	return out
}

const sec = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"

func build(t *testing.T, endpoints, events []string) *Config {
	t.Helper()
	var b Builder
	for _, e := range endpoints {
		if err := b.AddEndpoint(f(e)); err != nil {
			t.Fatalf("endpoint %q: %v", e, err)
		}
	}
	for _, e := range events {
		if err := b.AddEvent(f(e)); err != nil {
			t.Fatalf("event %q: %v", e, err)
		}
	}
	cfg, err := b.Config()
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestWorkedExample(t *testing.T) {
	cfg := build(t,
		[]string{
			"ep_a " + sec + " * 500,timeout,200",
			"ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200",
		},
		[]string{
			"msg_1 1700000000 user.created 7b7d",
			"msg_2 1700000100 repo.pushed 7b7d",
		})
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
	if got := string(Run(cfg).AppendTo(nil)); got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestRetrySchedule(t *testing.T) {
	cfg := build(t, []string{"e " + sec + " * 500"}, []string{"m 100 t -"})
	r := Run(cfg)
	want := []int64{100, 105, 405, 2205, 9405, 27405, 63405, 99405}
	if len(r.Attempts) != 8 {
		t.Fatalf("attempts = %d", len(r.Attempts))
	}
	for i, a := range r.Attempts {
		if a.Time != want[i] || a.N != i+1 {
			t.Errorf("attempt %d: %+v", i, a)
		}
	}
	if d := r.Deliveries[0]; d.Status != Failed || d.Attempts != 8 || d.LastTime != 99405 {
		t.Errorf("delivery %+v", d)
	}
}

func TestGoneDisablesEndpoint(t *testing.T) {
	cfg := build(t, []string{"e " + sec + " * 500,410"},
		[]string{"m1 0 t -", "m2 1 t -"})
	r := Run(cfg)
	// m1@0 -> 500, m2@1 -> 410 (gone, disables), m1 retry@5 -> disabled.
	if len(r.Attempts) != 2 {
		t.Fatalf("attempts: %+v", r.Attempts)
	}
	if OutcomeOf(r.Attempts[1].Response) != Gone {
		t.Fatalf("second attempt: %+v", r.Attempts[1])
	}
	d0, d1 := r.Deliveries[0], r.Deliveries[1]
	if d0.Status != Disabled || d0.Attempts != 1 || d0.LastTime != 0 {
		t.Errorf("d0 %+v", d0)
	}
	if d1.Status != Failed || d1.Attempts != 1 {
		t.Errorf("d1 %+v", d1)
	}
}

func TestDisabledWithoutAttempts(t *testing.T) {
	cfg := build(t, []string{"e " + sec + " * 410"}, []string{"a 0 t -", "b 5 t -"})
	out := string(Run(cfg).AppendTo(nil))
	if !strings.Contains(out, "delivery b e disabled 0 - ") {
		t.Fatalf("got:\n%s", out)
	}
}

func TestEventsProcessedInTimeOrder(t *testing.T) {
	cfg := build(t, []string{"e " + sec + " * 200"}, []string{"late 500 t -", "early 100 t -"})
	r := Run(cfg)
	if string(cfg.Events[r.Deliveries[r.Attempts[0].Delivery].Event].ID) != "early" {
		t.Fatalf("order: %+v", r.Attempts)
	}
}

func TestNoEvents(t *testing.T) {
	cfg := build(t, []string{"e " + sec + " * 200"}, nil)
	if got := string(Run(cfg).AppendTo(nil)); got != "sim 0 0\n" {
		t.Fatalf("got %q", got)
	}
}

func TestFilter(t *testing.T) {
	cfg := build(t, []string{"e " + sec + " a.b,c-d 200"}, nil)
	ep := &cfg.Endpoints[0]
	if !ep.Matches([]byte("a.b")) || !ep.Matches([]byte("c-d")) || ep.Matches([]byte("a")) || ep.Matches([]byte("a.bc")) {
		t.Fatal("filter wrong")
	}
}

func TestBuilderRejects(t *testing.T) {
	bad := []string{
		"e",                       // too few fields
		"e " + sec + " * 200 x",   // too many
		"e! " + sec + " * 200",    // bad id
		"e " + sec + " *,a 200",   // wildcard in list
		"e " + sec + " a,,b 200",  // empty entry
		"e " + sec + " * 99",      // code out of range
		"e " + sec + " * 600",     // code out of range
		"e " + sec + " * 20",      // not three digits
		"e " + sec + " * Timeout", // case-sensitive
		"e " + sec + " * 200,",    // empty entry
		"e A * 200",               // bad secret
		"e " + sec + " " + strings.Repeat("a,", 16) + "a 200",   // 17 filters
		"e " + sec + " * " + strings.Repeat("200,", 64) + "200", // 65 responses
	}
	for _, e := range bad {
		var b Builder
		if err := b.AddEndpoint(f(e)); err == nil {
			t.Errorf("accepted endpoint %q", e)
		}
	}
	var b Builder
	if _, err := b.Config(); err == nil {
		t.Error("config without endpoints accepted")
	}
	b.AddEndpoint(f("e " + sec + " * 200"))
	if err := b.AddEndpoint(f("e " + sec + " * 200")); err == nil {
		t.Error("duplicate endpoint id accepted")
	}
	for _, ev := range []string{"m 01 t -", "m 0 t! -", "m 0 t ABC", "m 0 t 0", "m"} {
		if err := b.AddEvent(f(ev)); err == nil {
			t.Errorf("accepted event %q", ev)
		}
	}
	if err := b.AddEvent(f("m 0 t -")); err != nil {
		t.Fatal(err)
	}
	if err := b.AddEvent(f("m 0 t -")); err == nil {
		t.Error("duplicate event id accepted")
	}
	if err := b.AddEndpoint(f("e2 " + sec + " * 200")); err == nil {
		t.Error("endpoint after event accepted")
	}
}

func TestLimits(t *testing.T) {
	var b Builder
	for i := 0; i < MaxEndpoints; i++ {
		if err := b.AddEndpoint(f("e" + strings.Repeat("x", i%3) + string(rune('A'+i/26)) + string(rune('a'+i%26)) + " " + sec + " * 200")); err != nil {
			t.Fatalf("endpoint %d: %v", i, err)
		}
	}
	if err := b.AddEndpoint(f("over " + sec + " * 200")); err == nil {
		t.Error("65th endpoint accepted")
	}
}
