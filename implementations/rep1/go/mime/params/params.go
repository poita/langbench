// Package params parses the structured header values of Content-Type,
// Content-Disposition and Content-Transfer-Encoding: a main value followed
// by ";"-separated parameters, including RFC 2231 continuations and extended
// (percent-encoded) values.
package params

import (
	"sort"
	"strings"

	"mimedump/charset"
	"mimedump/internal/scan"
	"mimedump/rfc2047"
)

// Value is a parsed structured header value.
type Value struct {
	// Main is the first segment, with spaces and tabs stripped but case kept.
	Main string
	// Params holds the effective parameter values by lower-cased name.
	Params map[string]string
}

// Get returns the effective value of the parameter called name.
func (v Value) Get(name string) (string, bool) {
	s, ok := v.Params[name]
	return s, ok
}

type raw struct{ name, value string }

// Parse parses the unfolded raw value of a header field. Parentheses are
// ordinary characters; comments are not recognised.
func Parse(value string) Value {
	segs := split(value)
	v := Value{Main: scan.Trim(segs[0]), Params: map[string]string{}}

	var rawParams []raw
	seen := map[string]bool{}
	for _, seg := range segs[1:] {
		eq := strings.IndexByte(seg, '=')
		if eq < 0 {
			continue
		}
		name := scan.LowerASCII(scan.Trim(seg[:eq]))
		if seen[name] {
			continue
		}
		seen[name] = true
		val := scan.Trim(seg[eq+1:])
		if strings.HasPrefix(val, "\"") {
			val, _ = scan.Quoted(val, 0)
		}
		rawParams = append(rawParams, raw{name, val})
	}
	v.assemble(rawParams)
	return v
}

// split cuts value at every ';' outside a quoted string.
func split(value string) []string {
	var out []string
	start := 0
	for i := 0; i < len(value); i++ {
		switch value[i] {
		case '"':
			_, next := scan.Quoted(value, i)
			i = next - 1
		case ';':
			out = append(out, value[start:i])
			start = i + 1
		}
	}
	return append(out, value[start:])
}

type segment struct {
	key      string // decimal number without leading zeros
	value    string
	extended bool
}

// classify interprets name as an RFC 2231 name. kind is 's' for base*N or
// base*N*, 'e' for base*, and 'p' for a plain name.
func classify(name string) (base string, seg segment, kind byte) {
	rest := name
	ext := strings.HasSuffix(rest, "*")
	if ext {
		rest = rest[:len(rest)-1]
	}
	d := len(rest)
	for d > 0 && rest[d-1] >= '0' && rest[d-1] <= '9' {
		d--
	}
	if d < len(rest) && d >= 2 && rest[d-1] == '*' {
		key := strings.TrimLeft(rest[d:], "0")
		if key == "" {
			key = "0"
		}
		return rest[:d-1], segment{key: key, extended: ext}, 's'
	}
	if ext && rest != "" {
		return rest, segment{}, 'e'
	}
	return name, segment{}, 'p'
}

func (v *Value) assemble(params []raw) {
	segs := map[string][]segment{}
	exts := map[string]string{}
	plains := map[string]string{}
	var order []string
	note := func(base string) {
		for _, b := range order {
			if b == base {
				return
			}
		}
		order = append(order, base)
	}
	for _, p := range params {
		base, seg, kind := classify(p.name)
		switch kind {
		case 's':
			seg.value = p.value
			segs[base] = append(segs[base], seg)
		case 'e':
			exts[base] = p.value
		default:
			plains[base] = p.value
		}
		note(base)
	}
	for _, base := range order {
		switch {
		case len(segs[base]) > 0:
			v.Params[base] = joinSegments(segs[base])
		case hasKey(exts, base):
			v.Params[base] = decodeExtended(exts[base])
		default:
			v.Params[base] = rfc2047.DecodeUnstructured(plains[base])
		}
	}
}

func hasKey(m map[string]string, k string) bool { _, ok := m[k]; return ok }

// joinSegments concatenates segments in increasing numeric order, keeping the
// first of any duplicates.
func joinSegments(segs []segment) string {
	sort.SliceStable(segs, func(i, j int) bool {
		a, b := segs[i].key, segs[j].key
		if len(a) != len(b) {
			return len(a) < len(b)
		}
		return a < b
	})
	cs := "us-ascii"
	var buf []byte
	for i, s := range segs {
		if i > 0 && segs[i-1].key == s.key {
			continue
		}
		if s.extended {
			text := s.value
			if s.key == "0" {
				var c string
				c, text = splitExtended(s.value)
				cs = c
			}
			buf = percentDecode(buf, text)
		} else {
			buf = append(buf, s.value...)
		}
	}
	return charset.Decode(buf, cs)
}

// splitExtended splits "charset'language'text". With an empty charset or
// fewer than two quotes the charset is us-ascii (and, without two quotes,
// the whole value is the text).
func splitExtended(s string) (cs, text string) {
	q1 := strings.IndexByte(s, '\'')
	if q1 < 0 {
		return "us-ascii", s
	}
	q2 := strings.IndexByte(s[q1+1:], '\'')
	if q2 < 0 {
		return "us-ascii", s
	}
	cs, text = s[:q1], s[q1+1+q2+1:]
	if cs == "" {
		cs = "us-ascii"
	}
	return cs, text
}

func decodeExtended(s string) string {
	cs, text := splitExtended(s)
	return charset.Decode(percentDecode(nil, text), cs)
}

func percentDecode(dst []byte, s string) []byte {
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) && scan.HexVal(s[i+1]) >= 0 && scan.HexVal(s[i+2]) >= 0 {
			dst = append(dst, byte(scan.HexVal(s[i+1])<<4|scan.HexVal(s[i+2])))
			i += 2
		} else {
			dst = append(dst, s[i])
		}
	}
	return dst
}
