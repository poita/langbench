// Package sim implements a deterministic webhook delivery simulator: events
// are signed for every matching endpoint and delivered through a fixed retry
// schedule against scripted endpoint responses.
package sim

import (
	"bytes"
	"errors"

	"webhooks/hexcodec"
	"webhooks/signature"
)

// Limits of a simulation.
const (
	MaxEndpoints = 64
	MaxEvents    = 20000
	MaxFilter    = 16
	MaxScript    = 64
	MaxNameLen   = 64
)

// ErrInvalid is returned for any malformed endpoint or event description, or
// a configuration that violates the limits.
var ErrInvalid = errors.New("sim: invalid configuration")

// Response is one scripted endpoint response: an HTTP status code 100..599,
// or Timeout.
type Response int16

// Timeout is the scripted response meaning "no answer".
const Timeout Response = 0

// Endpoint describes a receiving endpoint. The byte slices may alias the
// buffer they were parsed from, which must therefore stay unmodified.
type Endpoint struct {
	ID       []byte
	Secrets  []signature.Secret
	Wildcard bool     // deliver every event
	Filter   [][]byte // event types to deliver when !Wildcard
	Script   []Response
}

// Matches reports whether the endpoint's filter accepts an event type.
func (e *Endpoint) Matches(eventType []byte) bool {
	if e.Wildcard {
		return true
	}
	for _, f := range e.Filter {
		if bytes.Equal(f, eventType) {
			return true
		}
	}
	return false
}

// Event is something to deliver. TS is the timestamp text exactly as it is
// signed and sent; Time is its numeric value.
type Event struct {
	ID      []byte
	TS      []byte
	Time    int64
	Type    []byte
	Payload []byte
}

// Config is a complete, validated simulation input.
type Config struct {
	Endpoints []Endpoint
	Events    []Event
}

func isNameByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '_' || c == '.' || c == '-'
}

func validName(b []byte) bool {
	if len(b) == 0 || len(b) > MaxNameLen {
		return false
	}
	for _, c := range b {
		if !isNameByte(c) {
			return false
		}
	}
	return true
}

// Builder assembles a Config line by line, enforcing the grammar, ordering,
// uniqueness and size limits. The zero value is ready to use.
type Builder struct {
	cfg   Config
	epIDs map[string]struct{}
	evIDs map[string]struct{}
}

// AddEndpoint adds an endpoint from the fields following the "endpoint"
// keyword: ep-id, secrets, filter, script. Endpoints must precede events.
func (b *Builder) AddEndpoint(fields [][]byte) error {
	if len(fields) != 4 || len(b.cfg.Events) > 0 || len(b.cfg.Endpoints) >= MaxEndpoints {
		return ErrInvalid
	}
	id := fields[0]
	if !validName(id) || b.epIDs != nil && hasKey(b.epIDs, id) {
		return ErrInvalid
	}
	secrets, err := signature.ParseSecrets(fields[1])
	if err != nil {
		return ErrInvalid
	}
	ep := Endpoint{ID: id, Secrets: secrets}
	if string(fields[2]) == "*" {
		ep.Wildcard = true
	} else {
		rest := fields[2]
		for {
			i := bytes.IndexByte(rest, ',')
			entry := rest
			if i >= 0 {
				entry = rest[:i]
			}
			if !validName(entry) || len(ep.Filter) == MaxFilter {
				return ErrInvalid
			}
			ep.Filter = append(ep.Filter, entry)
			if i < 0 {
				break
			}
			rest = rest[i+1:]
		}
	}
	rest := fields[3]
	for {
		i := bytes.IndexByte(rest, ',')
		entry := rest
		if i >= 0 {
			entry = rest[:i]
		}
		r, ok := parseResponse(entry)
		if !ok || len(ep.Script) == MaxScript {
			return ErrInvalid
		}
		ep.Script = append(ep.Script, r)
		if i < 0 {
			break
		}
		rest = rest[i+1:]
	}
	if b.epIDs == nil {
		b.epIDs = make(map[string]struct{})
	}
	b.epIDs[string(id)] = struct{}{}
	b.cfg.Endpoints = append(b.cfg.Endpoints, ep)
	return nil
}

// AddEvent adds an event from the fields following the "event" keyword:
// ev-id, ts, type, payload-hex.
func (b *Builder) AddEvent(fields [][]byte) error {
	if len(fields) != 4 || len(b.cfg.Events) >= MaxEvents {
		return ErrInvalid
	}
	id := fields[0]
	if !validName(id) || b.evIDs != nil && hasKey(b.evIDs, id) {
		return ErrInvalid
	}
	t, ok := signature.ParseTimestamp(fields[1])
	if !ok || !validName(fields[2]) {
		return ErrInvalid
	}
	payload, err := hexcodec.DecodeArg(fields[3])
	if err != nil {
		return ErrInvalid
	}
	if b.evIDs == nil {
		b.evIDs = make(map[string]struct{})
	}
	b.evIDs[string(id)] = struct{}{}
	b.cfg.Events = append(b.cfg.Events, Event{ID: id, TS: fields[1], Time: t, Type: fields[2], Payload: payload})
	return nil
}

// Config finishes the build. It fails if there is no endpoint.
func (b *Builder) Config() (*Config, error) {
	if len(b.cfg.Endpoints) == 0 {
		return nil, ErrInvalid
	}
	return &b.cfg, nil
}

func hasKey(m map[string]struct{}, k []byte) bool {
	_, ok := m[string(k)]
	return ok
}

func parseResponse(b []byte) (Response, bool) {
	if string(b) == "timeout" {
		return Timeout, true
	}
	if len(b) != 3 {
		return 0, false
	}
	v := 0
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
	}
	if v < 100 || v > 599 {
		return 0, false
	}
	return Response(v), true
}
