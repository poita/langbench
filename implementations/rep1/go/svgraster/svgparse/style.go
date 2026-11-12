package svgparse

import "strings"

// Declarations maps lower-cased property names to trimmed values.
type Declarations map[string]string

// ParseStyle parses the value of a style attribute. Declarations without a
// ':' and declarations whose value is empty are ignored; for repeated
// properties the last one wins.
func ParseStyle(s string) Declarations {
	d := Declarations{}
	for _, part := range strings.Split(s, ";") {
		k := strings.IndexByte(part, ':')
		if k < 0 {
			continue
		}
		name := strings.ToLower(strings.TrimSpace(part[:k]))
		val := strings.TrimSpace(part[k+1:])
		if name == "" || val == "" {
			continue
		}
		d[name] = val
	}
	return d
}
