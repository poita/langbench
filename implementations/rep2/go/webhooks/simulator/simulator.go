// Package simulator is a deterministic webhook delivery simulator. Events are
// signed once per matching endpoint and delivered on a fixed retry schedule
// against scripted endpoint responses, with no real clock or network.
package simulator

import (
	"example.com/webhooks/hmac"
	"example.com/webhooks/signature"
)

// MaxAttempts is the number of attempts a delivery makes at most.
const MaxAttempts = 8

// RetryDelays[n-1] is the delay in seconds between attempt n and attempt n+1.
var RetryDelays = [MaxAttempts - 1]int64{5, 300, 1800, 7200, 18000, 36000, 36000}

// Response is one scripted endpoint response: an HTTP status code, or
// Timeout.
type Response int16

// Timeout is the scripted response that stands for a request timing out.
const Timeout Response = 0

// Endpoint describes a receiver. The simulator never modifies it.
type Endpoint struct {
	ID     string
	Keys   []*hmac.Key // active secrets, in order
	Types  []string    // event types delivered; empty means every type
	Script []Response  // responses by attempt; the last one repeats. Must be non-empty
}

func (e *Endpoint) matches(eventType string) bool {
	if len(e.Types) == 0 {
		return true
	}
	for _, t := range e.Types {
		if t == eventType {
			return true
		}
	}
	return false
}

// Event is something to deliver.
type Event struct {
	ID            string
	Type          string
	TimestampText string // timestamp exactly as it is sent and signed
	Timestamp     int64  // enqueue time, Unix seconds
	Payload       []byte
}

// Outcome is the result of one attempt.
type Outcome uint8

// Attempt outcomes.
const (
	Success Outcome = iota
	Failure
	TimedOut
	Gone
)

func (o Outcome) String() string {
	return [...]string{"success", "failure", "timeout", "gone"}[o]
}

// Status is the final state of a delivery.
type Status uint8

// Delivery statuses.
const (
	Delivered Status = iota
	Failed
	Disabled
)

func (s Status) String() string {
	return [...]string{"delivered", "failed", "disabled"}[s]
}

// Attempt is one recorded delivery attempt.
type Attempt struct {
	Delivery int32 // index into Result.Deliveries
	N        uint8 // 1-based attempt number within the delivery
	Time     int64
	Outcome  Outcome
	Code     Response // Timeout for a timed-out attempt
}

// Delivery is one (event, endpoint) pair and its final state.
type Delivery struct {
	Event, Endpoint int32 // indices into the slices given to Run
	Status          Status
	Attempts        uint8
	LastTime        int64 // time of the last attempt made; meaningless if Attempts == 0

	hdrOff, hdrLen int
}

// Result is the outcome of Run.
type Result struct {
	Events     []Event
	Endpoints  []Endpoint
	Attempts   []Attempt  // in processing order
	Deliveries []Delivery // in creation order
	headers    []byte
}

// Header returns the webhook-signature header value of delivery i.
func (r *Result) Header(i int) []byte {
	d := &r.Deliveries[i]
	return r.headers[d.hdrOff : d.hdrOff+d.hdrLen]
}

type item struct {
	time     int64
	delivery int32
}

func (a item) less(b item) bool {
	return a.time < b.time || a.time == b.time && a.delivery < b.delivery
}

// minHeap is a binary min-heap over a fixed-capacity backing array.
type minHeap struct{ a []item }

func (h *minHeap) up(i int) {
	a := h.a
	x := a[i]
	for i > 0 {
		p := (i - 1) / 2
		if !x.less(a[p]) {
			break
		}
		a[i] = a[p]
		i = p
	}
	a[i] = x
}

func (h *minHeap) down(i int) {
	a := h.a
	n := len(a)
	x := a[i]
	for {
		c := 2*i + 1
		if c >= n {
			break
		}
		if c+1 < n && a[c+1].less(a[c]) {
			c++
		}
		if !a[c].less(x) {
			break
		}
		a[i] = a[c]
		i = c
	}
	a[i] = x
}

func (h *minHeap) push(x item) {
	h.a = append(h.a, x)
	h.up(len(h.a) - 1)
}

// replaceTop swaps the minimum for x.
func (h *minHeap) replaceTop(x item) {
	h.a[0] = x
	h.down(0)
}

func (h *minHeap) pop() {
	n := len(h.a) - 1
	h.a[0] = h.a[n]
	h.a = h.a[:n]
	if n > 0 {
		h.down(0)
	}
}

// Run creates a delivery for every (event, matching endpoint) pair, in event
// then endpoint order, signs each once, and simulates the attempts in order of
// (scheduled time, delivery number). The inputs are not modified.
func Run(endpoints []Endpoint, events []Event) *Result {
	res := &Result{Events: events, Endpoints: endpoints}
	for ei := range events {
		ev := &events[ei]
		for pi := range endpoints {
			ep := &endpoints[pi]
			if !ep.matches(ev.Type) {
				continue
			}
			off := len(res.headers)
			res.headers = signature.AppendSignature(res.headers, ep.Keys, ev.ID, ev.TimestampText, ev.Payload)
			res.Deliveries = append(res.Deliveries, Delivery{
				Event: int32(ei), Endpoint: int32(pi),
				hdrOff: off, hdrLen: len(res.headers) - off,
			})
		}
	}

	dels := res.Deliveries
	h := minHeap{a: make([]item, len(dels), len(dels))}
	for i := range dels {
		h.a[i] = item{events[dels[i].Event].Timestamp, int32(i)}
	}
	for i := len(h.a)/2 - 1; i >= 0; i-- {
		h.down(i)
	}

	cursor := make([]int, len(endpoints))
	disabled := make([]bool, len(endpoints))
	for len(h.a) > 0 {
		it := h.a[0]
		d := &dels[it.delivery]
		epi := d.Endpoint
		if disabled[epi] {
			d.Status = Disabled
			h.pop()
			continue
		}
		script := endpoints[epi].Script
		c := cursor[epi]
		if c < len(script)-1 {
			cursor[epi]++
		} else {
			c = len(script) - 1
		}
		resp := script[c]
		d.Attempts++
		d.LastTime = it.time
		a := Attempt{Delivery: it.delivery, N: d.Attempts, Time: it.time, Code: resp}
		retry := false
		switch {
		case resp >= 200 && resp <= 299:
			a.Outcome = Success
			d.Status = Delivered
		case resp == 410:
			a.Outcome = Gone
			d.Status = Failed
			disabled[epi] = true
		case resp == Timeout:
			a.Outcome = TimedOut
			retry = true
		default:
			a.Outcome = Failure
			retry = true
		}
		res.Attempts = append(res.Attempts, a)
		if retry && d.Attempts < MaxAttempts {
			h.replaceTop(item{it.time + RetryDelays[d.Attempts-1], it.delivery})
			continue
		}
		if retry {
			d.Status = Failed
		}
		h.pop()
	}
	return res
}
