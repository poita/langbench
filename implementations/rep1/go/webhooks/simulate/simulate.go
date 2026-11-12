// Package simulate is a deterministic webhook delivery simulator.
//
// Events are signed and fanned out to the endpoints whose filters match them.
// Each resulting delivery is attempted up to eight times on a fixed retry
// schedule; endpoint behaviour is scripted rather than networked, so a run is
// a pure function of its Config.
package simulate

import (
	"example.com/webhooks"
)

// MaxAttempts is the number of attempts a delivery makes at most.
const MaxAttempts = 8

// RetryDelays[n-1] is the delay in seconds between attempt n and attempt n+1.
var RetryDelays = [MaxAttempts - 1]int64{5, 300, 1800, 7200, 18000, 36000, 36000}

// Response is one scripted endpoint response: an HTTP status code, or a
// timeout when Timeout is set (Code is then ignored).
type Response struct {
	Code    int
	Timeout bool
}

// Endpoint is a simulated receiver.
type Endpoint struct {
	ID     string
	Keys   [][]byte // raw HMAC keys of the active secrets, in order
	Filter []string // accepted event types; nil or empty means every type
	Script []Response
}

func (e *Endpoint) matches(eventType string) bool {
	if len(e.Filter) == 0 {
		return true
	}
	for _, f := range e.Filter {
		if f == eventType {
			return true
		}
	}
	return false
}

// Event is something to deliver.
type Event struct {
	ID        string
	Timestamp string // enqueue time exactly as it is sent in webhook-timestamp
	Time      int64  // the same moment as an integer (Unix seconds)
	Type      string
	Payload   []byte
}

// Config is the input of Run. Endpoints must be non-empty and every Script
// must contain at least one response.
type Config struct {
	Endpoints []Endpoint
	Events    []Event
}

// Outcome classifies a single attempt.
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
	case Gone:
		return "gone"
	}
	return "unknown"
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
	switch s {
	case Delivered:
		return "delivered"
	case Failed:
		return "failed"
	case Disabled:
		return "disabled"
	}
	return "unknown"
}

// Attempt is one recorded request. It is kept compact because a run can hold
// millions of them; resolve names through Result.Deliveries[Delivery].
type Attempt struct {
	Time     int64
	Delivery int32 // index into Result.Deliveries
	Code     uint16
	N        uint8 // 1-based attempt number within the delivery
	Outcome  Outcome
}

// Delivery is one (event, endpoint) pair.
type Delivery struct {
	Event    int32 // index into Config.Events
	Endpoint int32 // index into Config.Endpoints
	Status   Status
	Attempts uint8
	LastTime int64  // time of the last attempt made; valid if Attempts > 0
	Header   string // webhook-signature header, fixed at creation
}

// Result is the output of Run.
type Result struct {
	Attempts   []Attempt  // in processing order
	Deliveries []Delivery // in creation order
}

// item is a pending attempt in the queue.
type item struct {
	time     int64
	delivery int32
}

func (a item) less(b item) bool {
	return a.time < b.time || a.time == b.time && a.delivery < b.delivery
}

// queue is a binary min-heap of pending attempts.
type queue []item

func (q *queue) push(it item) {
	*q = append(*q, it)
	h := *q
	i := len(h) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !h[i].less(h[p]) {
			break
		}
		h[i], h[p] = h[p], h[i]
		i = p
	}
}

func (q *queue) pop() item {
	h := *q
	top := h[0]
	last := len(h) - 1
	h[0] = h[last]
	h = h[:last]
	*q = h
	i := 0
	for {
		l := 2*i + 1
		if l >= last {
			break
		}
		m := l
		if r := l + 1; r < last && h[r].less(h[l]) {
			m = r
		}
		if !h[m].less(h[i]) {
			break
		}
		h[i], h[m] = h[m], h[i]
		i = m
	}
	return top
}

// Run executes the simulation.
//
// Deliveries are created for each event in order and, within it, each matching
// endpoint in order, and are signed once at creation. Pending attempts are
// processed in (time, delivery number) order; see the package documentation
// and the project README for the retry and disabling rules.
func Run(cfg Config) *Result {
	res := &Result{}
	q := make(queue, 0, 16)

	for ei := range cfg.Events {
		ev := &cfg.Events[ei]
		for pi := range cfg.Endpoints {
			ep := &cfg.Endpoints[pi]
			if !ep.matches(ev.Type) {
				continue
			}
			d := int32(len(res.Deliveries))
			res.Deliveries = append(res.Deliveries, Delivery{
				Event:    int32(ei),
				Endpoint: int32(pi),
				Header:   webhooks.SignHeader(ep.Keys, ev.ID, ev.Timestamp, ev.Payload),
			})
			q.push(item{time: ev.Time, delivery: d})
		}
	}

	cursor := make([]int, len(cfg.Endpoints))
	disabled := make([]bool, len(cfg.Endpoints))

	for len(q) > 0 {
		it := q.pop()
		del := &res.Deliveries[it.delivery]
		if disabled[del.Endpoint] {
			del.Status = Disabled
			continue
		}
		ep := &cfg.Endpoints[del.Endpoint]
		ci := cursor[del.Endpoint]
		if ci >= len(ep.Script) {
			ci = len(ep.Script) - 1
		} else {
			cursor[del.Endpoint]++
		}
		resp := ep.Script[ci]

		del.Attempts++
		del.LastTime = it.time
		at := Attempt{Time: it.time, Delivery: it.delivery, N: del.Attempts}
		retry := false
		switch {
		case resp.Timeout:
			at.Outcome = TimedOut
			retry = true
		case resp.Code >= 200 && resp.Code <= 299:
			at.Outcome = Success
			at.Code = uint16(resp.Code)
			del.Status = Delivered
		case resp.Code == 410:
			at.Outcome = Gone
			at.Code = uint16(resp.Code)
			del.Status = Failed
			disabled[del.Endpoint] = true
		default:
			at.Outcome = Failure
			at.Code = uint16(resp.Code)
			retry = true
		}
		res.Attempts = append(res.Attempts, at)
		if !retry {
			continue
		}
		if del.Attempts == MaxAttempts {
			del.Status = Failed
			continue
		}
		q.push(item{time: it.time + RetryDelays[del.Attempts-1], delivery: it.delivery})
	}
	return res
}
