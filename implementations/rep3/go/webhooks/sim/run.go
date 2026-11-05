package sim

import (
	"strconv"

	"webhooks/signature"
)

// MaxAttempts is the number of attempts a delivery makes at most.
const MaxAttempts = 8

// retryDelay[n-1] is the delay in seconds from attempt n to attempt n+1.
var retryDelay = [MaxAttempts - 1]int64{5, 300, 1800, 7200, 18000, 36000, 36000}

// Status is the final state of a delivery.
type Status uint8

// Final delivery states.
const (
	Delivered Status = iota
	Failed
	Disabled
)

func (s Status) String() string {
	switch s {
	case Delivered:
		return "delivered"
	case Failed:
		return "failed"
	}
	return "disabled"
}

// Outcome classifies the result of one attempt.
type Outcome uint8

// Attempt outcomes.
const (
	Success Outcome = iota
	Failure
	TimedOut
	Gone
)

func (o Outcome) String() string {
	switch o {
	case Success:
		return "success"
	case Failure:
		return "failure"
	case TimedOut:
		return "timeout"
	}
	return "gone"
}

// OutcomeOf classifies a scripted response.
func OutcomeOf(r Response) Outcome {
	switch {
	case r == Timeout:
		return TimedOut
	case r >= 200 && r <= 299:
		return Success
	case r == 410:
		return Gone
	}
	return Failure
}

// Delivery is one event sent to one endpoint.
type Delivery struct {
	Event, Endpoint int // indices into Config.Events and Config.Endpoints
	Attempts        int // attempts made, 0..8
	LastTime        int64
	Status          Status
	hdrOff, hdrLen  int
}

// Attempt is one recorded delivery attempt.
type Attempt struct {
	Delivery int // index into Result.Deliveries
	N        int // 1-based attempt number
	Time     int64
	Response Response
}

// Result is the outcome of a simulation.
type Result struct {
	Config     *Config
	Deliveries []Delivery // in creation order: by event, then endpoint
	Attempts   []Attempt  // in processing order
	headers    []byte
}

// Header returns the webhook-signature header value of delivery i.
func (r *Result) Header(i int) []byte {
	d := &r.Deliveries[i]
	return r.headers[d.hdrOff : d.hdrOff+d.hdrLen]
}

type pending struct {
	time     int64
	delivery int
}

func less(a, b pending) bool {
	return a.time < b.time || a.time == b.time && a.delivery < b.delivery
}

// heap is a binary min-heap over reserved storage.
type heap struct{ a []pending }

func (h *heap) push(p pending) {
	h.a = append(h.a, p)
	i := len(h.a) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if !less(h.a[i], h.a[parent]) {
			break
		}
		h.a[i], h.a[parent] = h.a[parent], h.a[i]
		i = parent
	}
}

func (h *heap) down(i int) {
	n := len(h.a)
	for {
		l := 2*i + 1
		if l >= n {
			return
		}
		m := l
		if r := l + 1; r < n && less(h.a[r], h.a[l]) {
			m = r
		}
		if !less(h.a[m], h.a[i]) {
			return
		}
		h.a[i], h.a[m] = h.a[m], h.a[i]
		i = m
	}
}

func (h *heap) pop() pending {
	top := h.a[0]
	last := len(h.a) - 1
	h.a[0] = h.a[last]
	h.a = h.a[:last]
	h.down(0)
	return top
}

// Run executes the simulation described by cfg.
func Run(cfg *Config) *Result {
	res := &Result{Config: cfg}

	// Create and sign deliveries: events in order, matching endpoints in order.
	for ei := range cfg.Events {
		ev := &cfg.Events[ei]
		for pi := range cfg.Endpoints {
			ep := &cfg.Endpoints[pi]
			if !ep.Matches(ev.Type) {
				continue
			}
			off := len(res.headers)
			res.headers = signature.AppendHeader(res.headers, ep.Secrets, ev.ID, ev.TS, ev.Payload)
			res.Deliveries = append(res.Deliveries, Delivery{
				Event: ei, Endpoint: pi, hdrOff: off, hdrLen: len(res.headers) - off,
			})
		}
	}

	// Schedule first attempts (heapify) and run the queue.
	q := heap{a: make([]pending, len(res.Deliveries))}
	for i := range res.Deliveries {
		q.a[i] = pending{cfg.Events[res.Deliveries[i].Event].Time, i}
	}
	for i := len(q.a)/2 - 1; i >= 0; i-- {
		q.down(i)
	}
	cursor := make([]int, len(cfg.Endpoints))
	disabled := make([]bool, len(cfg.Endpoints))

	for len(q.a) > 0 {
		p := q.pop()
		d := &res.Deliveries[p.delivery]
		if disabled[d.Endpoint] {
			d.Status = Disabled
			continue
		}
		script := cfg.Endpoints[d.Endpoint].Script
		c := cursor[d.Endpoint]
		if c >= len(script) {
			c = len(script) - 1
		} else {
			cursor[d.Endpoint]++
		}
		resp := script[c]
		d.Attempts++
		d.LastTime = p.time
		res.Attempts = append(res.Attempts, Attempt{Delivery: p.delivery, N: d.Attempts, Time: p.time, Response: resp})
		switch OutcomeOf(resp) {
		case Success:
			d.Status = Delivered
		case Gone:
			d.Status = Failed
			disabled[d.Endpoint] = true
		default:
			if d.Attempts == MaxAttempts {
				d.Status = Failed
			} else {
				q.push(pending{p.time + retryDelay[d.Attempts-1], p.delivery})
			}
		}
	}
	return res
}

// AppendTo appends the textual report of the simulation to dst: a "sim A D"
// line, A attempt lines and D delivery lines, each terminated by '\n'.
func (r *Result) AppendTo(dst []byte) []byte {
	cfg := r.Config
	dst = append(dst, "sim "...)
	dst = strconv.AppendInt(dst, int64(len(r.Attempts)), 10)
	dst = append(dst, ' ')
	dst = strconv.AppendInt(dst, int64(len(r.Deliveries)), 10)
	dst = append(dst, '\n')
	for i, a := range r.Attempts {
		d := &r.Deliveries[a.Delivery]
		dst = append(dst, "attempt "...)
		dst = strconv.AppendInt(dst, int64(i+1), 10)
		dst = append(dst, ' ')
		dst = append(dst, cfg.Events[d.Event].ID...)
		dst = append(dst, ' ')
		dst = append(dst, cfg.Endpoints[d.Endpoint].ID...)
		dst = append(dst, ' ')
		dst = strconv.AppendInt(dst, int64(a.N), 10)
		dst = append(dst, ' ')
		dst = strconv.AppendInt(dst, a.Time, 10)
		dst = append(dst, ' ')
		dst = append(dst, OutcomeOf(a.Response).String()...)
		dst = append(dst, ' ')
		if a.Response == Timeout {
			dst = append(dst, '-')
		} else {
			dst = strconv.AppendInt(dst, int64(a.Response), 10)
		}
		dst = append(dst, '\n')
	}
	for i := range r.Deliveries {
		d := &r.Deliveries[i]
		dst = append(dst, "delivery "...)
		dst = append(dst, cfg.Events[d.Event].ID...)
		dst = append(dst, ' ')
		dst = append(dst, cfg.Endpoints[d.Endpoint].ID...)
		dst = append(dst, ' ')
		dst = append(dst, d.Status.String()...)
		dst = append(dst, ' ')
		dst = strconv.AppendInt(dst, int64(d.Attempts), 10)
		dst = append(dst, ' ')
		if d.Attempts == 0 {
			dst = append(dst, '-')
		} else {
			dst = strconv.AppendInt(dst, d.LastTime, 10)
		}
		dst = append(dst, ' ')
		dst = append(dst, r.Header(i)...)
		dst = append(dst, '\n')
	}
	return dst
}
