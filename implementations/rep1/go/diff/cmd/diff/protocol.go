package main

import (
	"errors"
	"fmt"
	"strconv"

	"linediff"
)

// reader walks the input buffer line by line, handing out views into it.
type reader struct {
	buf []byte
	pos int
}

// line returns the next line without its terminator ("\n" or "\r\n"). A final
// line without a terminator is accepted. At end of input it returns ok=false.
func (r *reader) line() (l []byte, ok bool) {
	if r.pos >= len(r.buf) {
		return nil, false
	}
	rest := r.buf[r.pos:]
	end := len(rest)
	next := end
	for i, c := range rest {
		if c == '\n' {
			end, next = i, i+1
			break
		}
	}
	r.pos += next
	l = rest[:end]
	if n := len(l); n > 0 && l[n-1] == '\r' {
		l = l[:n-1]
	}
	return l, true
}

// count reads a count line: ASCII digits, trailing spaces/tabs ignored.
func (r *reader) count() (int, error) {
	l, ok := r.line()
	if !ok {
		return 0, errors.New("unexpected end of input, want a count")
	}
	for len(l) > 0 && (l[len(l)-1] == ' ' || l[len(l)-1] == '\t') {
		l = l[:len(l)-1]
	}
	if len(l) == 0 || len(l) > 9 {
		return 0, fmt.Errorf("bad count line %q", l)
	}
	n := 0
	for _, c := range l {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("bad count line %q", l)
		}
		n = n*10 + int(c-'0')
	}
	return n, nil
}

// block reads a count line and then exactly that many content lines,
// regardless of what the lines look like.
func (r *reader) block() ([][]byte, error) {
	n, err := r.count()
	if err != nil {
		return nil, err
	}
	if n > len(r.buf)-r.pos { // every line needs at least one byte
		return nil, fmt.Errorf("count %d exceeds remaining input", n)
	}
	lines := make([][]byte, n)
	for i := range lines {
		l, ok := r.line()
		if !ok {
			return nil, fmt.Errorf("unexpected end of input after %d of %d lines", i, n)
		}
		lines[i] = l
	}
	return lines, nil
}

// Run implements the I/O contract: it parses input (mode line, then two
// counted blocks), runs the requested mode and returns the complete output.
func Run(input []byte) ([]byte, error) {
	r := &reader{buf: input}
	modeLine, ok := r.line()
	if !ok {
		return nil, errors.New("empty input")
	}
	for len(modeLine) > 0 && (modeLine[len(modeLine)-1] == ' ' || modeLine[len(modeLine)-1] == '\t') {
		modeLine = modeLine[:len(modeLine)-1]
	}
	mode := string(modeLine)
	if mode != "diff" && mode != "patch" {
		return nil, fmt.Errorf("unknown mode %q", mode)
	}
	a, err := r.block()
	if err != nil {
		return nil, fmt.Errorf("file A: %w", err)
	}
	second, err := r.block()
	if err != nil {
		return nil, fmt.Errorf("second block: %w", err)
	}

	if mode == "diff" {
		ops := linediff.Diff(a, second)
		return linediff.AppendScript(nil, a, second, ops), nil
	}

	script, err := linediff.ParseScript(second)
	if err != nil {
		return nil, err
	}
	b, err := linediff.Apply(a, script)
	if err != nil {
		return nil, err
	}
	size := 12
	for _, l := range b {
		size += len(l) + 1
	}
	out := make([]byte, 0, size)
	out = strconv.AppendInt(out, int64(len(b)), 10)
	out = append(out, '\n')
	for _, l := range b {
		out = append(out, l...)
		out = append(out, '\n')
	}
	return out, nil
}
