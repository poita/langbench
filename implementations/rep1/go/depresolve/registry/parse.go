package registry

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"depresolve/semver"
)

// Input is a parsed problem: the registry plus the root manifest.
type Input struct {
	Registry *Registry
	Root     []Requirement
}

// Parse reads the textual input format:
//
//	name X.Y.Z: dep range, dep range
//	...
//	root: dep range, dep range
//
// Zero or more registry lines are followed by exactly one root line, which
// comes last. A line with no requirements ends right after the colon.
func Parse(rd io.Reader) (*Input, error) {
	sc := bufio.NewReaderSize(rd, 1<<16)
	in := &Input{Registry: New()}
	haveRoot := false
	lineNo := 0
	for {
		line, err := sc.ReadString('\n')
		if err != nil && err != io.EOF {
			return nil, err
		}
		if line != "" {
			lineNo++
			if haveRoot {
				return nil, fmt.Errorf("line %d: content after the root line", lineNo)
			}
			line = strings.TrimSuffix(line, "\n")
			root, perr := parseLine(in.Registry, line)
			if perr != nil {
				return nil, fmt.Errorf("line %d: %w", lineNo, perr)
			}
			if root != nil {
				in.Root, haveRoot = *root, true
			}
		}
		if err == io.EOF {
			break
		}
	}
	if !haveRoot {
		return nil, fmt.Errorf("missing root line")
	}
	if err := in.Registry.Validate(); err != nil {
		return nil, err
	}
	return in, nil
}

// parseLine handles one line. For the root line it returns the requirements.
func parseLine(reg *Registry, line string) (*[]Requirement, error) {
	colon := strings.IndexByte(line, ':')
	if colon < 0 {
		return nil, fmt.Errorf("missing ':'")
	}
	head, tail := line[:colon], line[colon+1:]
	var reqText string
	if tail != "" {
		if tail[0] != ' ' {
			return nil, fmt.Errorf("expected space after ':'")
		}
		reqText = tail[1:]
	}
	reqs, err := ParseRequirements(reqText)
	if err != nil {
		return nil, err
	}
	if head == "root" {
		return &reqs, nil
	}
	sp := strings.IndexByte(head, ' ')
	if sp <= 0 {
		return nil, fmt.Errorf("expected 'name version' before ':'")
	}
	v, err := semver.ParseVersion(head[sp+1:])
	if err != nil {
		return nil, err
	}
	reg.Add(head[:sp], v, reqs)
	return nil, nil
}

// ParseRequirements parses a comma-separated requirement list such as
// "a ^1.0.0, b *". The empty string yields no requirements.
func ParseRequirements(s string) ([]Requirement, error) {
	if s == "" {
		return nil, nil
	}
	parts := strings.Split(s, ", ")
	reqs := make([]Requirement, 0, len(parts))
	for _, p := range parts {
		sp := strings.IndexByte(p, ' ')
		if sp <= 0 {
			return nil, fmt.Errorf("invalid requirement %q", p)
		}
		rg, err := semver.ParseRange(p[sp+1:])
		if err != nil {
			return nil, err
		}
		reqs = append(reqs, Requirement{Package: p[:sp], Range: rg})
	}
	return reqs, nil
}
