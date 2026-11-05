package depresolve

import (
	"fmt"
	"io"
	"strings"
)

// Parse reads the textual input format (registry lines followed by one
// "root:" line) and returns the registry and the root requirements.
//
//	name MAJOR.MINOR.PATCH: req, req, ...
//	root: req, req, ...
//
// where each req is "name range". See ParseRange for the range syntax.
func Parse(r io.Reader) (*Registry, []Requirement, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, nil, err
	}
	return ParseString(string(data))
}

// ParseString is like Parse but reads from a string.
func ParseString(s string) (*Registry, []Requirement, error) {
	reg := NewRegistry()
	var root []Requirement
	haveRoot := false
	lineNo := 0
	for len(s) > 0 {
		var line string
		if i := strings.IndexByte(s, '\n'); i >= 0 {
			line, s = s[:i], s[i+1:]
		} else {
			line, s = s, ""
		}
		lineNo++
		if haveRoot {
			return nil, nil, fmt.Errorf("line %d: content after root line", lineNo)
		}
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			return nil, nil, fmt.Errorf("line %d: missing ':'", lineNo)
		}
		head, tail := line[:colon], line[colon+1:]
		reqs, err := parseRequirements(tail)
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %v", lineNo, err)
		}
		if head == "root" {
			root, haveRoot = reqs, true
			continue
		}
		name, ver, ok := strings.Cut(head, " ")
		if !ok || name == "" {
			return nil, nil, fmt.Errorf("line %d: want \"name version:\"", lineNo)
		}
		v, err := ParseVersion(ver)
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %v", lineNo, err)
		}
		if err := reg.Add(name, v, reqs); err != nil {
			return nil, nil, fmt.Errorf("line %d: %v", lineNo, err)
		}
	}
	if !haveRoot {
		return nil, nil, fmt.Errorf("missing root line")
	}
	return reg, root, nil
}

// parseRequirements parses the text after the colon: "" or " req, req".
func parseRequirements(s string) ([]Requirement, error) {
	if s == "" {
		return nil, nil
	}
	if s[0] != ' ' {
		return nil, fmt.Errorf("expected space after ':'")
	}
	s = s[1:]
	n := strings.Count(s, ", ") + 1
	reqs := make([]Requirement, 0, n)
	for len(s) > 0 {
		var item string
		if i := strings.Index(s, ", "); i >= 0 {
			item, s = s[:i], s[i+2:]
		} else {
			item, s = s, ""
		}
		name, rng, ok := strings.Cut(item, " ")
		if !ok || name == "" {
			return nil, fmt.Errorf("invalid requirement %q", item)
		}
		r, err := ParseRange(rng)
		if err != nil {
			return nil, err
		}
		reqs = append(reqs, Requirement{name, r})
	}
	return reqs, nil
}

// Format renders a resolution as one "name version" line per package, each
// terminated by a newline. An empty resolution formats as "".
func (res Resolution) Format() string {
	var b strings.Builder
	for _, p := range res {
		b.WriteString(p.Name)
		b.WriteByte(' ')
		b.WriteString(p.Version.String())
		b.WriteByte('\n')
	}
	return b.String()
}
