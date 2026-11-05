// Package sim is a deterministic webhook delivery simulator. It signs events
// for every matching endpoint and replays them against scripted endpoint
// responses on a fixed retry schedule, using a virtual clock.
package sim

import (
	"fmt"

	"example.com/webhooks/signature"
)

// MaxAttempts is the maximum number of attempts per delivery.
const MaxAttempts = 8

// RetryDelays[n-1] is the delay in seconds between attempt n and attempt n+1:
// 5s, 5m, 30m, 2h, 5h, 10h, 10h.
var RetryDelays = [MaxAttempts - 1]int64{5, 300, 1800, 7200, 18000, 36000, 36000}

// Timeout is the Response value meaning "no answer"; any other Response is an
// HTTP status code.
const Timeout Response = 0

// Response is one entry of an endpoint script: a status code, or Timeout.
type Response int16

// Endpoint is a webhook receiver.
type Endpoint struct {
	ID       string
	Secrets  []*signature.Secret // active signing keys, in header order
	Wildcard bool                // deliver every event type
	Types    []string            // event types delivered when !Wildcard
	Script   []Response          // successive responses; the last repeats forever
}

// Matches reports whether the endpoint receives events of the given type.
func (e *Endpoint) Matches(eventType string) bool {
	if e.Wildcard {
		return true
	}
	for _, t := range e.Types {
		if t == eventType {
			return true
		}
	}
	return false
}

// Event is a message to be delivered to every matching endpoint.
type Event struct {
	ID        string
	Timestamp string // webhook-timestamp text, exactly as written
	Time      int64  // Timestamp parsed: when the event is enqueued
	Type      string
	Payload   []byte
}

// NewEvent builds an Event, parsing ts as a canonical timestamp.
func NewEvent(id, ts, eventType string, payload []byte) (Event, error) {
	t, ok := signature.ParseTimestamp(ts)
	if !ok {
		return Event{}, fmt.Errorf("sim: invalid timestamp %q", ts)
	}
	return Event{ID: id, Timestamp: ts, Time: t, Type: eventType, Payload: payload}, nil
}

// Outcome classifies one attempt.
type Outcome uint8

// Attempt outcomes.
const (
	Success  Outcome = iota // 2xx
	Failure                 // any other status code; retryable
	TimedOut                // no response; retryable
	Gone                    // 410; permanent, disables the endpoint
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

// Attempt records one request made to an endpoint.
type Attempt struct {
	Delivery int32 // index into Result.Deliveries
	N        uint8 // 1-based attempt number within the delivery
	Time     int64 // scheduled time
	Outcome  Outcome
	Code     Response // status code, or Timeout
}

// Delivery is one (event, endpoint) pair and what became of it.
type Delivery struct {
	Event, Endpoint int32 // indices into the inputs
	Status          Status
	Attempts        uint8
	LastTime        int64  // time of the last attempt made; meaningless if Attempts == 0
	Header          string // webhook-signature header, fixed at creation
}
