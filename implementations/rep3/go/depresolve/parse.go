package depresolve

import (
	"fmt"
	"io"
	"strings"
)

// Parse parses the text format: zero or more registry lines
//
//	name MAJOR.MINOR.PATCH: req, req, ...
//
// followed by exactly one root line "root: req, req, ..." as the last line.
// A requirement is "name range" (see ParseRange). A line with nothing after
// the colon has no requirements. Every line ends with "\n"; the final
// newline may be omitted.
func Parse(input string) (*Problem, error) {
	var b Builder
	seenRoot := false
	for line := 1; len(input) > 0; line++ {
		var text string
		if i := strings.IndexByte(input, '\n'); i >= 0 {
			text, input = input[:i], input[i+1:]
		} else {
			text, input = input, ""
		}
		if seenRoot {
			return nil, fmt.Errorf("line %d: data after the root line", line)
		}
		if err := b.parseLine(text, &seenRoot); err != nil {
			return nil, fmt.Errorf("line %d: %w", line, err)
		}
	}
	if !seenRoot {
		return nil, fmt.Errorf("missing root line")
	}
	return b.Build()
}

// ParseReader reads all of r and parses it with Parse.
func ParseReader(r io.Reader) (*Problem, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	return Parse(string(data))
}

func (b *Builder) parseLine(text string, seenRoot *bool) error {
	colon := strings.IndexByte(text, ':')
	if colon < 0 {
		return fmt.Errorf("missing ':'")
	}
	head, tail := text[:colon], text[colon+1:]

	if head == "root" {
		*seenRoot = true
		start, n, err := b.parseReqs(tail)
		b.rootStart, b.rootCount = start, n
		return err
	}
	sp := strings.IndexByte(head, ' ')
	if sp < 0 {
		return fmt.Errorf("want \"name version:\"")
	}
	name := head[:sp]
	if !ValidName(name) {
		return fmt.Errorf("invalid package name %q", name)
	}
	v, err := ParseVersion(head[sp+1:])
	if err != nil {
		return err
	}
	id := b.intern(name)
	start, n, err := b.parseReqs(tail)
	if err != nil {
		return err
	}
	b.vers = append(b.vers, verRec{pkg: id, reqStart: start, reqCount: n, key: v.key()})
	return nil
}

// parseReqs parses the text after the colon, appending to b.reqs.
func (b *Builder) parseReqs(s string) (start, count int32, err error) {
	start = int32(len(b.reqs))
	if s == "" {
		return start, 0, nil
	}
	if s[0] != ' ' {
		return 0, 0, fmt.Errorf("want a space after ':'")
	}
	s = s[1:]
	for {
		item := s
		more := false
		if i := strings.Index(s, ", "); i >= 0 {
			item, s, more = s[:i], s[i+2:], true
		}
		sp := strings.IndexByte(item, ' ')
		if sp < 0 {
			return 0, 0, fmt.Errorf("invalid requirement %q", item)
		}
		name := item[:sp]
		if !ValidName(name) {
			return 0, 0, fmt.Errorf("invalid package name %q", name)
		}
		r, err := ParseRange(item[sp+1:])
		if err != nil {
			return 0, 0, err
		}
		b.addReq(name, r)
		count++
		if !more {
			return start, count, nil
		}
	}
}
