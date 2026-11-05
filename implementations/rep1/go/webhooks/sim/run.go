package sim

import "example.com/webhooks/signature"

// Result is the outcome of a simulation. Attempts are in processing order;
// Deliveries are in creation order (event order, then endpoint order).
type Result struct {
	Endpoints  []Endpoint
	Events     []Event
	Attempts   []Attempt
	Deliveries []Delivery
}

// Run simulates delivering events to endpoints. Each event is delivered to
// every endpoint whose filter matches; each delivery is signed once with all
// of that endpoint's secrets and then attempted up to MaxAttempts times,
// always processing the earliest pending attempt (ties broken by delivery
// number). Endpoints must have non-empty scripts. The inputs are not
// modified.
func Run(endpoints []Endpoint, events []Event) *Result {
	r := &Result{Endpoints: endpoints, Events: events}

	for ei := range events {
		ev := &events[ei]
		for pi := range endpoints {
			ep := &endpoints[pi]
			if !ep.Matches(ev.Type) {
				continue
			}
			r.Deliveries = append(r.Deliveries, Delivery{
				Event:    int32(ei),
				Endpoint: int32(pi),
				Header:   signature.Sign(ep.Secrets, ev.ID, ev.Timestamp, ev.Payload),
			})
		}
	}

	start := make([]item, len(r.Deliveries))
	for d := range r.Deliveries {
		start[d] = item{r.Events[r.Deliveries[d].Event].Time, int32(d)}
	}
	queue := newHeap(start, len(start))

	cursor := make([]int, len(endpoints))
	disabled := make([]bool, len(endpoints))

	for queue.len() > 0 {
		it := queue.pop()
		dl := &r.Deliveries[it.delivery]
		if disabled[dl.Endpoint] {
			dl.Status = Disabled
			continue
		}
		script := endpoints[dl.Endpoint].Script
		c := cursor[dl.Endpoint]
		cursor[dl.Endpoint]++
		resp := script[min(c, len(script)-1)]

		dl.Attempts++
		dl.LastTime = it.time
		at := Attempt{Delivery: it.delivery, N: dl.Attempts, Time: it.time, Code: resp}
		retry := false
		switch {
		case resp == Timeout:
			at.Outcome, retry = TimedOut, true
		case resp >= 200 && resp <= 299:
			at.Outcome = Success
			dl.Status = Delivered
		case resp == 410:
			at.Outcome = Gone
			dl.Status = Failed
			disabled[dl.Endpoint] = true
		default:
			at.Outcome, retry = Failure, true
		}
		r.Attempts = append(r.Attempts, at)
		if !retry {
			continue
		}
		if dl.Attempts == MaxAttempts {
			dl.Status = Failed
		} else {
			queue.push(item{it.time + RetryDelays[dl.Attempts-1], it.delivery})
		}
	}
	return r
}
