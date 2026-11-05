package commands

import (
	"bytes"

	"example.com/webhooks/hexfield"
	"example.com/webhooks/sim"
)

// cmdSimulate reads a simulate block (the "simulate" line has just been
// consumed) and prints its report, or "error" if any line violates the block
// grammar. After the first violation the remaining lines are only compared
// against "end".
func (e *executor) cmdSimulate() {
	if len(e.fields) != 1 {
		e.fail()
		return
	}
	var (
		endpoints []sim.Endpoint
		events    []sim.Event
		epIDs     = map[string]struct{}{}
		evIDs     = map[string]struct{}{}
		bad       bool
		closed    bool
	)
	for {
		line, ok := e.nextLine()
		if !ok {
			break
		}
		if isBlank(line) {
			continue
		}
		if string(line) == "end" {
			closed = true
			break
		}
		if bad {
			continue
		}
		e.fields = splitFields(e.fields, line)
		f := e.fields
		switch {
		case hasEmpty(f), len(f) != 5:
			bad = true
		case string(f[0]) == "endpoint" && len(events) == 0 && len(endpoints) < maxEndpoints:
			ep, ok := parseEndpoint(f)
			if _, dup := epIDs[ep.ID]; !ok || dup {
				bad = true
				break
			}
			epIDs[ep.ID] = struct{}{}
			endpoints = append(endpoints, ep)
		case string(f[0]) == "event" && len(events) < maxEvents:
			ev, ok := parseEvent(f)
			if _, dup := evIDs[ev.ID]; !ok || dup {
				bad = true
				break
			}
			evIDs[ev.ID] = struct{}{}
			events = append(events, ev)
		default:
			bad = true
		}
	}
	if !closed || bad || len(endpoints) == 0 {
		e.fail()
		return
	}
	e.out = sim.Run(endpoints, events).AppendReport(e.out)
}

// parseEndpoint parses: endpoint <ep-id> <secrets> <filter> <script>.
func parseEndpoint(f [][]byte) (sim.Endpoint, bool) {
	var ep sim.Endpoint
	if !isName(f[1]) {
		return ep, false
	}
	ep.ID = string(f[1])
	var ok bool
	if ep.Secrets, ok = parseSecrets(f[2]); !ok {
		return ep, false
	}
	if len(f[3]) == 1 && f[3][0] == '*' {
		ep.Wildcard = true
	} else {
		for rest := f[3]; ; {
			t := rest
			i := bytes.IndexByte(rest, ',')
			if i >= 0 {
				t = rest[:i]
			}
			if !isName(t) || len(ep.Types) == maxFilterTypes {
				return ep, false
			}
			ep.Types = append(ep.Types, string(t))
			if i < 0 {
				break
			}
			rest = rest[i+1:]
		}
	}
	for rest := f[4]; ; {
		r := rest
		i := bytes.IndexByte(rest, ',')
		if i >= 0 {
			r = rest[:i]
		}
		resp, ok := parseResponse(r)
		if !ok || len(ep.Script) == maxScript {
			return ep, false
		}
		ep.Script = append(ep.Script, resp)
		if i < 0 {
			break
		}
		rest = rest[i+1:]
	}
	return ep, true
}

func parseResponse(r []byte) (sim.Response, bool) {
	if string(r) == "timeout" {
		return sim.Timeout, true
	}
	if len(r) != 3 {
		return 0, false
	}
	n := 0
	for _, c := range r {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	if n < 100 || n > 599 {
		return 0, false
	}
	return sim.Response(n), true
}

// parseEvent parses: event <ev-id> <ts> <type> <payload-hex>.
func parseEvent(f [][]byte) (sim.Event, bool) {
	if !isName(f[1]) || !isName(f[3]) {
		return sim.Event{}, false
	}
	if _, ok := parseInt(f[2]); !ok {
		return sim.Event{}, false
	}
	payload, err := hexfield.Decode(f[4])
	if err != nil {
		return sim.Event{}, false
	}
	ev, err := sim.NewEvent(string(f[1]), string(f[2]), string(f[3]), payload)
	return ev, err == nil
}
