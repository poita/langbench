package simulator_test

import (
	"strings"
	"testing"

	"example.com/webhooks/hmac"
	"example.com/webhooks/signature"
	"example.com/webhooks/simulator"
)

func key(t *testing.T, s string) []*hmac.Key {
	t.Helper()
	k, err := signature.ParseSecret(s)
	if err != nil {
		t.Fatal(err)
	}
	return []*hmac.Key{k}
}

func script(codes ...int) []simulator.Response {
	var s []simulator.Response
	for _, c := range codes {
		s = append(s, simulator.Response(c))
	}
	return s
}

func event(id, typ string, ts int64) simulator.Event {
	return simulator.Event{ID: id, Type: typ, TimestampText: itoa(ts), Timestamp: ts, Payload: []byte("{}")}
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var b []byte
	for ; v > 0; v /= 10 {
		b = append([]byte{byte('0' + v%10)}, b...)
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}

// lines of the report without the signature header column.
func report(r *simulator.Result) []string {
	var out []string
	for _, l := range strings.Split(strings.TrimSpace(string(r.AppendReport(nil))), "\n") {
		if strings.HasPrefix(l, "delivery ") {
			f := strings.SplitN(l, " ", 7)
			l = strings.Join(f[:6], " ")
		}
		out = append(out, l)
	}
	return out
}

func eq(t *testing.T, got, want []string) {
	t.Helper()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestSpecExample(t *testing.T) {
	eps := []simulator.Endpoint{
		{ID: "ep_a", Keys: key(t, "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"), Script: script(500, 0, 200)},
		{ID: "ep_b", Keys: key(t, "whsec_c2VjcmV0"), Types: []string{"user.created"}, Script: script(200)},
	}
	evs := []simulator.Event{event("msg_1", "user.created", 1700000000), event("msg_2", "repo.pushed", 1700000100)}
	res := simulator.Run(eps, evs)
	eq(t, report(res), []string{
		"sim 5 3",
		"attempt 1 msg_1 ep_a 1 1700000000 failure 500",
		"attempt 2 msg_1 ep_b 1 1700000000 success 200",
		"attempt 3 msg_1 ep_a 2 1700000005 timeout -",
		"attempt 4 msg_2 ep_a 1 1700000100 success 200",
		"attempt 5 msg_1 ep_a 3 1700000305 success 200",
		"delivery msg_1 ep_a delivered 3 1700000305",
		"delivery msg_1 ep_b delivered 1 1700000000",
		"delivery msg_2 ep_a delivered 1 1700000100",
	})
	// The header is the signature of the payload with the endpoint's secrets.
	want := signature.Sign(eps[0].Keys, "msg_1", "1700000000", []byte("{}"))
	if string(res.Header(0)) != want {
		t.Errorf("header %s want %s", res.Header(0), want)
	}
}

func TestRetryScheduleAndExhaustion(t *testing.T) {
	eps := []simulator.Endpoint{{ID: "e", Keys: key(t, "AAAA"), Script: script(500)}}
	res := simulator.Run(eps, []simulator.Event{event("x", "t", 100)})
	var times []int64
	for _, a := range res.Attempts {
		times = append(times, a.Time)
	}
	want := []int64{100, 105, 405, 2205, 9405, 27405, 63405, 99405}
	if len(times) != len(want) {
		t.Fatalf("attempt times %v", times)
	}
	for i := range want {
		if times[i] != want[i] {
			t.Fatalf("attempt times %v want %v", times, want)
		}
	}
	d := res.Deliveries[0]
	if d.Status != simulator.Failed || d.Attempts != 8 || d.LastTime != 99405 {
		t.Errorf("delivery %+v", d)
	}
}

func TestGoneDisablesEndpoint(t *testing.T) {
	eps := []simulator.Endpoint{{ID: "e", Keys: key(t, "AAAA"), Script: script(500, 410, 200)}}
	evs := []simulator.Event{event("a", "t", 0), event("b", "t", 1)}
	res := simulator.Run(eps, evs)
	eq(t, report(res), []string{
		"sim 2 2",
		"attempt 1 a e 1 0 failure 500",
		"attempt 2 b e 1 1 gone 410",
		"delivery a e disabled 1 0",
		"delivery b e failed 1 1",
	})
}

func TestNoMatchingEndpointAndOrdering(t *testing.T) {
	eps := []simulator.Endpoint{{ID: "e", Keys: key(t, "AAAA"), Types: []string{"only"}, Script: script(200)}}
	res := simulator.Run(eps, []simulator.Event{event("a", "other", 0)})
	eq(t, report(res), []string{"sim 0 0"})

	// Equal times break ties by delivery number; earlier ts runs first even when declared later.
	eps = []simulator.Endpoint{{ID: "e", Keys: key(t, "AAAA"), Script: script(500, 200)}}
	res = simulator.Run(eps, []simulator.Event{event("late", "t", 100), event("early", "t", 0)})
	eq(t, report(res), []string{
		"sim 3 2",
		"attempt 1 early e 1 0 failure 500",
		"attempt 2 early e 2 5 success 200",
		"attempt 3 late e 1 100 success 200",
		"delivery late e delivered 1 100",
		"delivery early e delivered 2 5",
	})
}

func TestRunDoesNotMutateInputs(t *testing.T) {
	eps := []simulator.Endpoint{{ID: "e", Keys: key(t, "AAAA"), Script: script(410)}}
	evs := []simulator.Event{event("a", "t", 0)}
	first := string(simulator.Run(eps, evs).AppendReport(nil))
	second := string(simulator.Run(eps, evs).AppendReport(nil))
	if first != second {
		t.Fatal("runs differ")
	}
}

func TestManyDeliveriesStayOrdered(t *testing.T) {
	eps := []simulator.Endpoint{{ID: "e", Keys: key(t, "AAAA"), Script: script(500, 200)}}
	var evs []simulator.Event
	for i := 0; i < 2000; i++ {
		evs = append(evs, event("e"+itoa(int64(i)), "t", int64((i*7919)%1000)))
	}
	res := simulator.Run(eps, evs)
	for i := 1; i < len(res.Attempts); i++ {
		a, b := res.Attempts[i-1], res.Attempts[i]
		if a.Time > b.Time || a.Time == b.Time && a.Delivery > b.Delivery {
			t.Fatalf("attempts %d and %d out of order", i-1, i)
		}
	}
}
