package depresolve

import (
	"bytes"
	"fmt"
	"io"
	"strings"
)

// Problem is a registry together with the root manifest to resolve.
type Problem struct {
	Registry *Registry
	Root     []Requirement
}

// Resolve resolves the root requirements against the registry.
func (p *Problem) Resolve() (Resolution, error) { return p.Registry.Resolve(p.Root) }

// ParseError reports a malformed line of input.
type ParseError struct {
	Line int // 1-based
	Err  error
}

func (e *ParseError) Error() string { return fmt.Sprintf("line %d: %v", e.Line, e.Err) }
func (e *ParseError) Unwrap() error { return e.Err }

// Parse reads a problem in the text format:
//
//	name 1.2.3: dep ^1.0.0, other >=2.0.0 <3.0.0
//	...
//	root: name *, other ~2.1.0
//
// that is, zero or more registry lines followed by exactly one root line,
// each terminated by "\n". The final newline may be missing. Parse reads r to
// the end.
func Parse(r io.Reader) (*Problem, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	return ParseBytes(data)
}

// ParseBytes is like Parse for data already in memory.
func ParseBytes(data []byte) (*Problem, error) {
	p := &Problem{Registry: NewRegistry()}
	haveRoot := false
	line := 0
	for len(data) > 0 {
		line++
		var text []byte
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			text, data = data[:i], data[i+1:]
		} else {
			text, data = data, nil
		}
		if haveRoot {
			return nil, &ParseError{line, fmt.Errorf("content after the root line")}
		}
		if err := p.parseLine(string(text)); err != nil {
			return nil, &ParseError{line, err}
		}
		haveRoot = p.Root != nil
	}
	if !haveRoot {
		return nil, &ParseError{line + 1, fmt.Errorf("missing root line")}
	}
	return p, nil
}

func (p *Problem) parseLine(text string) error {
	colon := strings.IndexByte(text, ':')
	if colon < 0 {
		return fmt.Errorf("missing ':'")
	}
	head, tail := text[:colon], text[colon+1:]
	reqs, err := parseRequirements(tail)
	if err != nil {
		return err
	}
	if head == "root" {
		if reqs == nil {
			reqs = []Requirement{}
		}
		p.Root = reqs
		return nil
	}
	name, ver, ok := strings.Cut(head, " ")
	if !ok || name == "" {
		return fmt.Errorf("want \"name version:\", got %q", head)
	}
	v, err := ParseVersion(ver)
	if err != nil {
		return err
	}
	return p.Registry.Add(name, v, reqs)
}

// parseRequirements parses the text after the colon: empty, or a space
// followed by requirements separated by ", ".
func parseRequirements(s string) ([]Requirement, error) {
	if s == "" {
		return nil, nil
	}
	if s[0] != ' ' {
		return nil, fmt.Errorf("want a space after ':'")
	}
	s = s[1:]
	reqs := make([]Requirement, 0, strings.Count(s, ", ")+1)
	for s != "" {
		var item string
		if i := strings.Index(s, ", "); i >= 0 {
			item, s = s[:i], s[i+2:]
		} else {
			item, s = s, ""
		}
		name, rng, ok := strings.Cut(item, " ")
		if !ok || name == "" {
			return nil, fmt.Errorf("want \"name range\", got %q", item)
		}
		r, err := ParseRange(rng)
		if err != nil {
			return nil, err
		}
		reqs = append(reqs, Requirement{name, r})
	}
	return reqs, nil
}
