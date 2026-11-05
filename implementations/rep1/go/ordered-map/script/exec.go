package script

import (
	"strconv"

	"github.com/example/ordered-map/orderedmap"
)

// Execute runs the script in input and returns the output: one line per
// command. A script whose first line is missing or whose command count exceeds
// the number of lines present is processed as far as it goes.
func Execute(input []byte) []byte {
	c := cursor{buf: input}
	first, ok := c.line()
	if !ok {
		return nil
	}
	q := int(parseCount(first))
	m := orderedmap.New(q)
	out := make([]byte, 0, 1<<16)
	for ; q > 0; q-- {
		line, ok := c.line()
		if !ok {
			break
		}
		out = Exec(m, line, out)
	}
	return out
}

// Exec runs a single command line against m and appends its response line
// (including the trailing newline) to out. Malformed commands are ignored and
// produce no output.
func Exec(m *orderedmap.Map, line, out []byte) []byte {
	cmd, args := token(line)
	if len(cmd) < 3 {
		return out
	}
	switch cmd[0] {
	case 'i': // insert
		keyTok, val := token(args)
		if m.Put(parseInt(keyTok), val) {
			return append(out, "ok\n"...)
		}
		return append(out, "updated\n"...)
	case 'd': // delete
		if m.Delete(parseInt(args)) {
			return append(out, "ok\n"...)
		}
		return append(out, "missing\n"...)
	case 'g': // get
		if v, ok := m.Get(parseInt(args)); ok {
			out = append(out, v...)
			return append(out, '\n')
		}
		return append(out, "missing\n"...)
	case 's': // size, succ, select
		switch cmd[1] {
		case 'i':
			out = strconv.AppendInt(out, int64(m.Len()), 10)
			return append(out, '\n')
		case 'u':
			k, ok := m.Successor(parseInt(args))
			return keyLine(out, "missing\n", k, ok)
		default:
			idx := parseCount(args)
			if idx >= int64(m.Len()) {
				return append(out, "missing\n"...)
			}
			k, ok := m.Select(int(idx))
			return keyLine(out, "missing\n", k, ok)
		}
	case 'm': // min, max
		if cmd[1] == 'i' {
			k, ok := m.Min()
			return keyLine(out, "empty\n", k, ok)
		}
		k, ok := m.Max()
		return keyLine(out, "empty\n", k, ok)
	case 'f':
		k, ok := m.Floor(parseInt(args))
		return keyLine(out, "missing\n", k, ok)
	case 'c':
		k, ok := m.Ceil(parseInt(args))
		return keyLine(out, "missing\n", k, ok)
	case 'p':
		k, ok := m.Predecessor(parseInt(args))
		return keyLine(out, "missing\n", k, ok)
	case 'r': // range, rank
		if len(cmd) == 4 {
			out = strconv.AppendInt(out, int64(m.Rank(parseInt(args))), 10)
			return append(out, '\n')
		}
		loTok, hiTok := token(args)
		return appendRange(m, out, parseInt(loTok), parseInt(hiTok))
	}
	return out
}

// keyLine appends the key followed by a newline, or the fallback line none
// when ok is false.
func keyLine(out []byte, none string, k int64, ok bool) []byte {
	if !ok {
		return append(out, none...)
	}
	out = strconv.AppendInt(out, k, 10)
	return append(out, '\n')
}

func appendRange(m *orderedmap.Map, out []byte, lo, hi int64) []byte {
	start := len(out)
	m.Ascend(lo, hi, func(k int64, _ []byte) bool {
		if len(out) > start {
			out = append(out, ' ')
		}
		out = strconv.AppendInt(out, k, 10)
		return true
	})
	if len(out) == start {
		out = append(out, "empty"...)
	}
	return append(out, '\n')
}
