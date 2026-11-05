package protocol

import (
	"example.com/webhooks/signature"
	"example.com/webhooks/simulator"
	"strconv"
)

const (
	maxEndpoints = 64
	maxEvents    = 20000
	maxFilter    = 16
	maxScript    = 64
)

func appendInt(dst []byte, v int) []byte { return strconv.AppendInt(dst, int64(v), 10) }

// blockParser accumulates the lines of a simulate block.
type blockParser struct {
	endpoints []simulator.Endpoint
	events    []simulator.Event
	epIDs     map[string]struct{}
	evIDs     map[string]struct{}
}

// simulate consumes a block (the "simulate" line has been read) and appends
// either the simulation report or "error".
func (r *reader) simulate(out []byte) []byte {
	p := &blockParser{epIDs: map[string]struct{}{}, evIDs: map[string]struct{}{}}
	bad, closed := false, false
	var fields [][]byte
	for {
		line, ok := r.next()
		if !ok {
			break
		}
		if string(line) == "end" {
			closed = true
			break
		}
		if bad || isBlank(line) {
			continue
		}
		var fieldsOK bool
		fields, fieldsOK = splitFields(line, fields)
		if !fieldsOK || !p.line(fields) {
			bad = true
		}
	}
	if !closed || bad || len(p.endpoints) == 0 {
		return append(out, errorLine...)
	}
	return simulator.Run(p.endpoints, p.events).AppendReport(out)
}

func (p *blockParser) line(f [][]byte) bool {
	if len(f) != 5 {
		return false
	}
	switch string(f[0]) {
	case "endpoint":
		return len(p.events) == 0 && p.endpoint(f)
	case "event":
		return p.event(f)
	}
	return false
}

func (p *blockParser) endpoint(f [][]byte) bool {
	if len(p.endpoints) >= maxEndpoints {
		return false
	}
	id, ok := parseName(f[1])
	if !ok {
		return false
	}
	if _, dup := p.epIDs[id]; dup {
		return false
	}
	keys, ok := parseSecrets(f[2])
	if !ok {
		return false
	}
	types, ok := parseFilter(f[3])
	if !ok {
		return false
	}
	script, ok := parseScript(f[4])
	if !ok {
		return false
	}
	p.epIDs[id] = struct{}{}
	p.endpoints = append(p.endpoints, simulator.Endpoint{ID: id, Keys: keys, Types: types, Script: script})
	return true
}

func (p *blockParser) event(f [][]byte) bool {
	if len(p.events) >= maxEvents {
		return false
	}
	id, ok := parseName(f[1])
	if !ok {
		return false
	}
	if _, dup := p.evIDs[id]; dup {
		return false
	}
	ts, ok := signature.ParseTimestamp(f[2])
	if !ok {
		return false
	}
	typ, ok := parseName(f[3])
	if !ok {
		return false
	}
	payload, ok := decodeHex(f[4])
	if !ok {
		return false
	}
	p.evIDs[id] = struct{}{}
	p.events = append(p.events, simulator.Event{
		ID: id, Type: typ, TimestampText: string(f[2]), Timestamp: ts, Payload: payload,
	})
	return true
}

// parseFilter parses "*" (nil: every type) or 1..16 comma-separated types.
func parseFilter(f []byte) ([]string, bool) {
	if len(f) == 1 && f[0] == '*' {
		return nil, true
	}
	var types []string
	start := 0
	for i := 0; i <= len(f); i++ {
		if i == len(f) || f[i] == ',' {
			if len(types) == maxFilter {
				return nil, false
			}
			t, ok := parseName(f[start:i])
			if !ok {
				return nil, false
			}
			types = append(types, t)
			start = i + 1
		}
	}
	return types, true
}

// parseScript parses 1..64 comma-separated responses: a status code 100..599
// or the word "timeout".
func parseScript(f []byte) ([]simulator.Response, bool) {
	var script []simulator.Response
	start := 0
	for i := 0; i <= len(f); i++ {
		if i == len(f) || f[i] == ',' {
			if len(script) == maxScript {
				return nil, false
			}
			tok := f[start:i]
			start = i + 1
			if string(tok) == "timeout" {
				script = append(script, simulator.Timeout)
				continue
			}
			if len(tok) != 3 || tok[0] < '1' || tok[0] > '5' {
				return nil, false
			}
			if tok[1] < '0' || tok[1] > '9' || tok[2] < '0' || tok[2] > '9' {
				return nil, false
			}
			script = append(script, simulator.Response(int(tok[0]-'0')*100+int(tok[1]-'0')*10+int(tok[2]-'0')))
		}
	}
	return script, true
}
