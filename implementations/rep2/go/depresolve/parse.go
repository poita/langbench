package depresolve

import (
	"fmt"
	"io"
	"strings"
)

// Parse reads the textual input format: zero or more registry lines
//
//	name MAJOR.MINOR.PATCH: req, req, ...
//
// followed by exactly one root line
//
//	root: req, req, ...
//
// Every line ends with a newline. It returns the registry and the root
// requirements.
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
		nl := strings.IndexByte(s, '\n')
		if nl < 0 {
			return nil, nil, fmt.Errorf("line %d: missing newline", lineNo+1)
		}
		line, s = s[:nl], s[nl+1:]
		lineNo++
		if haveRoot {
			return nil, nil, fmt.Errorf("line %d: content after root line", lineNo)
		}
		head, reqText, ok := strings.Cut(line, ":")
		if !ok {
			return nil, nil, fmt.Errorf("line %d: missing ':'", lineNo)
		}
		reqText = strings.TrimPrefix(reqText, " ")
		reqs, err := ParseRequirements(reqText)
		if err != nil {
			return nil, nil, fmt.Errorf("line %d: %v", lineNo, err)
		}
		if head == "root" {
			root, haveRoot = reqs, true
			continue
		}
		name, ver, ok := strings.Cut(head, " ")
		if !ok || !ValidName(name) {
			return nil, nil, fmt.Errorf("line %d: invalid package declaration %q", lineNo, head)
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
