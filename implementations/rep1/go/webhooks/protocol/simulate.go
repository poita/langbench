package protocol

import (
	"bufio"
	"strconv"
	"strings"

	"example.com/webhooks"
	"example.com/webhooks/simulate"
)

const (
	maxEndpoints = 64
	maxEvents    = 20000
)

func itoa(n int) string { return strconv.Itoa(n) }

// runSimulate consumes a simulate block (after the opening line) and writes
// its output, or "error" if the block is malformed.
func runSimulate(lines *lineReader, w *bufio.Writer) {
	cfg, ok := readBlock(lines)
	if !ok {
		w.WriteString(errorLine + "\n")
		return
	}
	writeResult(w, cfg, simulate.Run(*cfg))
}

// readBlock reads block lines up to and including "end". After the first
// violation the remaining lines are skipped until a line that is exactly
// "end" (or EOF).
func readBlock(lines *lineReader) (*simulate.Config, bool) {
	cfg := &simulate.Config{}
	epIDs := map[string]bool{}
	evIDs := map[string]bool{}
	bad := false
	for {
		line, ok := lines.next()
		if !ok {
			return nil, false // EOF before end
		}
		if line == "end" {
			return cfg, !bad && len(cfg.Endpoints) > 0
		}
		if bad || isBlank(line) {
			continue
		}
		f := strings.Split(line, " ")
		switch {
		case f[0] == "endpoint" && len(cfg.Events) == 0:
			ep, ok := parseEndpoint(f)
			if !ok || epIDs[ep.ID] || len(cfg.Endpoints) >= maxEndpoints {
				bad = true
				continue
			}
			epIDs[ep.ID] = true
			cfg.Endpoints = append(cfg.Endpoints, ep)
		case f[0] == "event":
			ev, ok := parseEvent(f)
			if !ok || evIDs[ev.ID] || len(cfg.Events) >= maxEvents {
				bad = true
				continue
			}
			evIDs[ev.ID] = true
			cfg.Events = append(cfg.Events, ev)
		default:
			bad = true
		}
	}
}

func parseEndpoint(f []string) (simulate.Endpoint, bool) {
	var ep simulate.Endpoint
	if len(f) != 5 || !isName(f[1]) {
		return ep, false
	}
	keys, err1 := parseSecrets(f[2])
	filter, err2 := parseFilter(f[3])
	script, err3 := parseScript(f[4])
	if err1 != nil || err2 != nil || err3 != nil {
		return ep, false
	}
	return simulate.Endpoint{ID: f[1], Keys: keys, Filter: filter, Script: script}, true
}

func parseEvent(f []string) (simulate.Event, bool) {
	var ev simulate.Event
	if len(f) != 5 || !isName(f[1]) || !isName(f[3]) {
		return ev, false
	}
	t, err := webhooks.ParseInt(f[2])
	if err != nil {
		return ev, false
	}
	payload, err := parseHex(f[4])
	if err != nil {
		return ev, false
	}
	return simulate.Event{ID: f[1], Timestamp: f[2], Time: t, Type: f[3], Payload: payload}, true
}

func writeResult(w *bufio.Writer, cfg *simulate.Config, res *simulate.Result) {
	var buf []byte
	buf = append(buf, "sim "...)
	buf = strconv.AppendInt(buf, int64(len(res.Attempts)), 10)
	buf = append(buf, ' ')
	buf = strconv.AppendInt(buf, int64(len(res.Deliveries)), 10)
	buf = append(buf, '\n')
	w.Write(buf)

	for i, a := range res.Attempts {
		d := &res.Deliveries[a.Delivery]
		buf = append(buf[:0], "attempt "...)
		buf = strconv.AppendInt(buf, int64(i+1), 10)
		buf = append(buf, ' ')
		buf = append(buf, cfg.Events[d.Event].ID...)
		buf = append(buf, ' ')
		buf = append(buf, cfg.Endpoints[d.Endpoint].ID...)
		buf = append(buf, ' ')
		buf = strconv.AppendInt(buf, int64(a.N), 10)
		buf = append(buf, ' ')
		buf = strconv.AppendInt(buf, a.Time, 10)
		buf = append(buf, ' ')
		buf = append(buf, a.Outcome.String()...)
		buf = append(buf, ' ')
		if a.Outcome == simulate.TimedOut {
			buf = append(buf, '-')
		} else {
			buf = strconv.AppendInt(buf, int64(a.Code), 10)
		}
		buf = append(buf, '\n')
		w.Write(buf)
	}
	for i := range res.Deliveries {
		d := &res.Deliveries[i]
		buf = append(buf[:0], "delivery "...)
		buf = append(buf, cfg.Events[d.Event].ID...)
		buf = append(buf, ' ')
		buf = append(buf, cfg.Endpoints[d.Endpoint].ID...)
		buf = append(buf, ' ')
		buf = append(buf, d.Status.String()...)
		buf = append(buf, ' ')
		buf = strconv.AppendInt(buf, int64(d.Attempts), 10)
		buf = append(buf, ' ')
		if d.Attempts == 0 {
			buf = append(buf, '-')
		} else {
			buf = strconv.AppendInt(buf, d.LastTime, 10)
		}
		buf = append(buf, ' ')
		buf = append(buf, d.Header...)
		buf = append(buf, '\n')
		w.Write(buf)
	}
}
