package sim_test

import (
	"strings"
	"testing"

	"example.com/webhooks/signature"
	"example.com/webhooks/sim"
)

func secret(t *testing.T, s string) []*signature.Secret {
	t.Helper()
	sec, err := signature.ParseSecret(s)
	if err != nil {
		t.Fatal(err)
	}
	return []*signature.Secret{sec}
}

func event(t *testing.T, id, ts, typ string) sim.Event {
	t.Helper()
	ev, err := sim.NewEvent(id, ts, typ, []byte("{}"))
	if err != nil {
		t.Fatal(err)
	}
	return ev
}

func report(r *sim.Result) []string {
	return strings.Split(strings.TrimSuffix(string(r.AppendReport(nil)), "\n"), "\n")
}

func TestRetrySchedule(t *testing.T) {
	eps := []sim.Endpoint{{ID: "e", Secrets: secret(t, "c2VjcmV0"), Wildcard: true, Script: []sim.Response{500}}}
	r := sim.Run(eps, []sim.Event{event(t, "m", "1000", "x")})
	want := []int64{1000, 1005, 1305, 3105, 10305, 28305, 64305, 100305}
	if len(r.Attempts) != 8 {
		t.Fatalf("attempts = %d", len(r.Attempts))
	}
	for i, a := range r.Attempts {
		if a.Time != want[i] || int(a.N) != i+1 || a.Outcome != sim.Failure {
			t.Errorf("attempt %d = %+v", i, a)
		}
	}
	d := r.Deliveries[0]
	if d.Status != sim.Failed || d.Attempts != 8 || d.LastTime != 100305 {
		t.Errorf("delivery = %+v", d)
	}
}

func TestScriptCursorAndTimeout(t *testing.T) {
	eps := []sim.Endpoint{{ID: "e", Secrets: secret(t, "c2VjcmV0"), Wildcard: true,
		Script: []sim.Response{500, sim.Timeout, 200}}}
	r := sim.Run(eps, []sim.Event{event(t, "m", "0", "x")})
	got := report(r)
	if got[1] != "attempt 1 m e 1 0 failure 500" || got[2] != "attempt 2 m e 2 5 timeout -" ||
		got[3] != "attempt 3 m e 3 305 success 200" || !strings.HasPrefix(got[4], "delivery m e delivered 3 305 v1,") {
		t.Errorf("report:\n%s", strings.Join(got, "\n"))
	}
}

func TestGoneDisablesEndpoint(t *testing.T) {
	// Delivery 0 gets 410 at t=0; delivery 1 (enqueued later) never gets
	// attempted; delivery 2 had already failed once and is cut off on retry.
	eps := []sim.Endpoint{{ID: "e", Secrets: secret(t, "c2VjcmV0"), Wildcard: true,
		Script: []sim.Response{500, 410}}}
	evs := []sim.Event{event(t, "a", "0", "x"), event(t, "b", "100", "x")}
	r := sim.Run(eps, evs)
	if r.Deliveries[0].Status != sim.Failed || r.Deliveries[0].Attempts != 2 {
		t.Errorf("a: %+v", r.Deliveries[0])
	}
	// a: 500 at 0, 410 at 5 -> disabled; b first attempt at 100 is disabled.
	if d := r.Deliveries[1]; d.Status != sim.Disabled || d.Attempts != 0 {
		t.Errorf("b: %+v", d)
	}
	if last := report(r)[len(report(r))-1]; !strings.HasPrefix(last, "delivery b e disabled 0 - v1,") {
		t.Errorf("last line %q", last)
	}
}

func TestOrderingByTimeThenDelivery(t *testing.T) {
	eps := []sim.Endpoint{{ID: "e", Secrets: secret(t, "c2VjcmV0"), Wildcard: true, Script: []sim.Response{200}}}
	evs := []sim.Event{event(t, "late", "50", "x"), event(t, "early", "10", "x"), event(t, "tie", "50", "x")}
	r := sim.Run(eps, evs)
	var order []string
	for _, a := range r.Attempts {
		order = append(order, r.Events[r.Deliveries[a.Delivery].Event].ID)
	}
	if strings.Join(order, ",") != "early,late,tie" {
		t.Errorf("order = %v", order)
	}
}

func TestFilter(t *testing.T) {
	ep := sim.Endpoint{Types: []string{"a.b", "c"}}
	if !ep.Matches("a.b") || !ep.Matches("c") || ep.Matches("a") || ep.Matches("a.b.c") {
		t.Error("filter matching wrong")
	}
	if all := (sim.Endpoint{Wildcard: true}); !all.Matches("anything") {
		t.Error("wildcard should match")
	}
}

func TestNewEventRejectsBadTimestamp(t *testing.T) {
	if _, err := sim.NewEvent("e", "01", "t", nil); err == nil {
		t.Error("non-canonical timestamp accepted")
	}
}

func TestSignatureSharedHeaderFixedAcrossRetries(t *testing.T) {
	sec := secret(t, "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
	eps := []sim.Endpoint{{ID: "e", Secrets: sec, Wildcard: true, Script: []sim.Response{500, 200}}}
	ev := event(t, "m", "1700000000", "x")
	r := sim.Run(eps, []sim.Event{ev})
	if want := signature.Sign(sec, "m", "1700000000", ev.Payload); r.Deliveries[0].Header != want {
		t.Errorf("header %q want %q", r.Deliveries[0].Header, want)
	}
}
