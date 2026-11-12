package simulate

import (
	"testing"
)

func key(b byte) [][]byte { return [][]byte{{b}} }

func codes(cs ...int) []Response {
	var out []Response
	for _, c := range cs {
		if c == 0 {
			out = append(out, Response{Timeout: true})
		} else {
			out = append(out, Response{Code: c})
		}
	}
	return out
}

func TestRetrySchedule(t *testing.T) {
	cfg := Config{
		Endpoints: []Endpoint{{ID: "a", Keys: key(1), Script: codes(500)}},
		Events:    []Event{{ID: "e", Timestamp: "100", Time: 100, Type: "t"}},
	}
	res := Run(cfg)
	want := []int64{100, 105, 405, 2205, 9405, 27405, 63405, 99405}
	if len(res.Attempts) != 8 {
		t.Fatalf("got %d attempts", len(res.Attempts))
	}
	for i, a := range res.Attempts {
		if a.Time != want[i] || int(a.N) != i+1 || a.Outcome != Failure {
			t.Errorf("attempt %d = %+v", i, a)
		}
	}
	d := res.Deliveries[0]
	if d.Status != Failed || d.Attempts != 8 || d.LastTime != 99405 {
		t.Errorf("delivery = %+v", d)
	}
}

func TestGoneDisablesEndpoint(t *testing.T) {
	cfg := Config{
		Endpoints: []Endpoint{{ID: "a", Keys: key(1), Script: codes(500, 410)}},
		Events: []Event{
			{ID: "e1", Timestamp: "0", Time: 0, Type: "t"},
			{ID: "e2", Timestamp: "1", Time: 1, Type: "t"},
		},
	}
	res := Run(cfg)
	// e1@0 -> 500; e2@1 -> 410 (disables); e1 retry@5 -> disabled.
	d0, d1 := res.Deliveries[0], res.Deliveries[1]
	if d0.Status != Disabled || d0.Attempts != 1 || d0.LastTime != 0 {
		t.Errorf("d0 = %+v", d0)
	}
	if d1.Status != Failed || d1.Attempts != 1 {
		t.Errorf("d1 = %+v", d1)
	}
	if len(res.Attempts) != 2 || res.Attempts[1].Outcome != Gone {
		t.Errorf("attempts = %+v", res.Attempts)
	}
}

func TestDisabledWithoutAttempts(t *testing.T) {
	cfg := Config{
		Endpoints: []Endpoint{{ID: "a", Keys: key(1), Script: codes(410)}},
		Events: []Event{
			{ID: "e1", Timestamp: "0", Time: 0, Type: "t"},
			{ID: "e2", Timestamp: "0", Time: 0, Type: "t"},
		},
	}
	res := Run(cfg)
	if d := res.Deliveries[1]; d.Status != Disabled || d.Attempts != 0 {
		t.Errorf("d1 = %+v", d)
	}
}

func TestFilterAndOrdering(t *testing.T) {
	cfg := Config{
		Endpoints: []Endpoint{
			{ID: "all", Keys: key(1), Script: codes(200)},
			{ID: "only-x", Keys: key(2), Filter: []string{"x"}, Script: codes(200)},
		},
		Events: []Event{
			{ID: "late", Timestamp: "50", Time: 50, Type: "y"},
			{ID: "early", Timestamp: "10", Time: 10, Type: "x"},
		},
	}
	res := Run(cfg)
	if len(res.Deliveries) != 3 {
		t.Fatalf("deliveries = %d", len(res.Deliveries))
	}
	// Processing order is by time: early/all, early/only-x, late/all.
	var order []int32
	for _, a := range res.Attempts {
		order = append(order, a.Delivery)
	}
	if len(order) != 3 || order[0] != 1 || order[1] != 2 || order[2] != 0 {
		t.Errorf("order = %v", order)
	}
}

func TestScriptCursorSharedPerEndpoint(t *testing.T) {
	cfg := Config{
		Endpoints: []Endpoint{{ID: "a", Keys: key(1), Script: codes(500, 0, 200)}},
		Events:    []Event{{ID: "e", Timestamp: "0", Time: 0, Type: "t"}},
	}
	res := Run(cfg)
	outs := []Outcome{Failure, TimedOut, Success}
	for i, a := range res.Attempts {
		if a.Outcome != outs[i] {
			t.Errorf("attempt %d outcome %v", i, a.Outcome)
		}
	}
}

func TestHeap(t *testing.T) {
	var q queue
	in := []item{{5, 1}, {3, 2}, {5, 0}, {1, 9}, {3, 1}, {7, 3}}
	for _, it := range in {
		q.push(it)
	}
	want := []item{{1, 9}, {3, 1}, {3, 2}, {5, 0}, {5, 1}, {7, 3}}
	for i, w := range want {
		if got := q.pop(); got != w {
			t.Errorf("pop %d = %v, want %v", i, got, w)
		}
	}
}
