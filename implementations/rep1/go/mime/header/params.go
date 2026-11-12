package header

import (
	"sort"
	"strings"

	"example.com/mime/charset"
	"example.com/mime/internal/lex"
	"example.com/mime/rfc2047"
	"example.com/mime/transfer"
)

// Structured is a parsed Content-Type, Content-Disposition or
// Content-Transfer-Encoding value: the value proper plus its parameters.
type Structured struct {
	// Value is the first segment of the header, stripped of blanks but not
	// case-folded.
	Value string
	// Params maps parameter names (lower case) to their effective values after
	// RFC 2231 assembly and RFC 2047 decoding.
	Params map[string]string
}

// Token returns the value proper, stripped and lower-cased.
func (s Structured) Token() string { return strings.ToLower(s.Value) }

// Param returns the named parameter and whether it exists.
func (s Structured) Param(name string) (string, bool) {
	v, ok := s.Params[name]
	return v, ok
}

type rawParam struct{ name, value string }

// ParseStructured parses a raw header value. Parentheses are ordinary
// characters; only quoted strings are special.
func ParseStructured(raw string) Structured {
	var segs []string
	start := 0
	for i := 0; i < len(raw); {
		switch raw[i] {
		case '"':
			i = lex.SkipQuoted(raw, i)
		case ';':
			segs = append(segs, raw[start:i])
			i++
			start = i
		default:
			i++
		}
	}
	segs = append(segs, raw[start:])

	st := Structured{Value: lex.Strip(segs[0])}
	var params []rawParam
	seen := map[string]bool{}
	for _, seg := range segs[1:] {
		eq := strings.IndexByte(seg, '=')
		if eq < 0 {
			continue
		}
		name := strings.ToLower(lex.Strip(seg[:eq]))
		if seen[name] {
			continue
		}
		seen[name] = true
		val := lex.Strip(seg[eq+1:])
		if strings.HasPrefix(val, "\"") {
			val, _ = lex.QuotedString(val, 0)
		}
		params = append(params, rawParam{name, val})
	}
	st.Params = assemble(params)
	return st
}

type segment struct {
	num      string // decimal digits without leading zeros
	value    string
	extended bool
}

// splitName classifies a parameter name: base*N, base*N* (segment), base*
// (extended) or plain.
func splitName(name string) (base string, num string, kind int) {
	const (
		plain = iota
		seg
		ext
	)
	trimmed := name
	star := false
	if strings.HasSuffix(trimmed, "*") {
		trimmed = trimmed[:len(trimmed)-1]
		star = true
	}
	// base*N / base*N*
	k := len(trimmed)
	for k > 0 && trimmed[k-1] >= '0' && trimmed[k-1] <= '9' {
		k--
	}
	if k < len(trimmed) && k >= 2 && trimmed[k-1] == '*' {
		digits := strings.TrimLeft(trimmed[k:], "0")
		if digits == "" {
			digits = "0"
		}
		return trimmed[:k-1], digits, seg
	}
	if star && trimmed != "" {
		return trimmed, "", ext
	}
	return name, "", plain
}

func assemble(params []rawParam) map[string]string {
	const (
		plain = iota
		seg
		ext
	)
	out := make(map[string]string, len(params))
	type group struct {
		plain    *string
		extended *string
		segs     []segment
		segNums  map[string]bool
	}
	groups := map[string]*group{}
	var order []string
	get := func(base string) *group {
		g := groups[base]
		if g == nil {
			g = &group{segNums: map[string]bool{}}
			groups[base] = g
			order = append(order, base)
		}
		return g
	}
	for _, p := range params {
		base, num, kind := splitName(p.name)
		v := p.value
		switch kind {
		case plain:
			get(base).plain = &v
		case ext:
			get(base).extended = &v
		case seg:
			g := get(base)
			if g.segNums[num] {
				continue
			}
			g.segNums[num] = true
			g.segs = append(g.segs, segment{num, v, strings.HasSuffix(p.name, "*")})
		}
	}
	for _, base := range order {
		g := groups[base]
		switch {
		case len(g.segs) > 0:
			sort.SliceStable(g.segs, func(i, j int) bool {
				a, b := g.segs[i].num, g.segs[j].num
				if len(a) != len(b) {
					return len(a) < len(b)
				}
				return a < b
			})
			cs := "us-ascii"
			var buf []byte
			for _, s := range g.segs {
				val := s.value
				if s.extended {
					if s.num == "0" {
						var c string
						c, val = splitExtended(val)
						cs = c
					}
					buf = append(buf, percentDecode(val)...)
				} else {
					buf = append(buf, val...)
				}
			}
			out[base] = charset.Decode(buf, cs)
		case g.extended != nil:
			cs, text := splitExtended(*g.extended)
			out[base] = charset.Decode(percentDecode(text), cs)
		case g.plain != nil:
			out[base] = rfc2047.DecodeUnstructured(*g.plain)
		}
	}
	return out
}

// splitExtended splits "charset'language'text". With fewer than two
// apostrophes the whole value is the text and the charset is us-ascii, as it
// is when the charset field is empty.
func splitExtended(v string) (cs, text string) {
	i := strings.IndexByte(v, '\'')
	if i < 0 {
		return "us-ascii", v
	}
	j := strings.IndexByte(v[i+1:], '\'')
	if j < 0 {
		return "us-ascii", v
	}
	cs = v[:i]
	if cs == "" {
		cs = "us-ascii"
	}
	return cs, v[i+1+j+1:]
}

// percentDecode decodes %XX escapes; any other % is literal.
func percentDecode(s string) []byte {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '%' && i+2 < len(s) && transfer.HexValue(s[i+1]) >= 0 && transfer.HexValue(s[i+2]) >= 0 {
			out = append(out, byte(transfer.HexValue(s[i+1])<<4|transfer.HexValue(s[i+2])))
			i += 2
			continue
		}
		out = append(out, s[i])
	}
	return out
}
