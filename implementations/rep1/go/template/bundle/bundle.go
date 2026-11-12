// Package bundle parses the input format of the command-line tool: a JSON
// context, a line `--`, and then named templates, each introduced by a
// header line `=== <name>`.
package bundle

import (
	"errors"
	"strings"
)

// Template is a named template body.
type Template struct {
	Name string
	Body string
}

// Bundle is a parsed input: the JSON context text and the templates in file
// order. The first template is the one to render.
type Bundle struct {
	Context   string
	Templates []Template
}

const (
	separator    = "--"
	headerPrefix = "=== "
)

// ErrNoSeparator is returned when the input has no `--` line.
var ErrNoSeparator = errors.New("bundle: missing '--' separator line")

// ErrNoTemplate is returned when the input has no template after the separator.
var ErrNoTemplate = errors.New("bundle: no template after the separator")

// Parse splits input into its context and templates.
//
// A template body is the text after its header line's newline up to the
// newline preceding the next header line; for the last template it runs to
// the end of the input, minus one trailing newline.
func Parse(input string) (*Bundle, error) {
	// Find the first line that is exactly "--".
	ctxEnd, rest := -1, ""
	for pos := 0; pos <= len(input); {
		nl := strings.IndexByte(input[pos:], '\n')
		end := len(input)
		if nl >= 0 {
			end = pos + nl
		}
		if input[pos:end] == separator {
			ctxEnd = pos
			rest = input[min(end+1, len(input)):]
			break
		}
		if nl < 0 {
			break
		}
		pos = end + 1
	}
	if ctxEnd < 0 {
		return nil, ErrNoSeparator
	}
	b := &Bundle{Context: input[:ctxEnd]}

	type header struct {
		name       string
		start, end int // the header line is rest[start:end]; its body starts at end+1
	}
	var headers []header
	for pos := 0; pos < len(rest); {
		nl := strings.IndexByte(rest[pos:], '\n')
		end := len(rest)
		if nl >= 0 {
			end = pos + nl
		}
		if strings.HasPrefix(rest[pos:end], headerPrefix) {
			headers = append(headers, header{rest[pos+len(headerPrefix) : end], pos, end})
		}
		pos = end + 1
	}
	if len(headers) == 0 {
		return nil, ErrNoTemplate
	}
	for i, h := range headers {
		bodyStart := min(h.end+1, len(rest))
		var body string
		if i+1 < len(headers) {
			bodyEnd := max(headers[i+1].start-1, bodyStart)
			body = rest[bodyStart:bodyEnd]
		} else {
			body = strings.TrimSuffix(rest[bodyStart:], "\n")
		}
		b.Templates = append(b.Templates, Template{Name: h.name, Body: body})
	}
	return b, nil
}
