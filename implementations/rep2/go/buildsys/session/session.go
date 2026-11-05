// Package session parses session scripts (session.txt) and drives a whole
// Kiln session: a sequence of builds and workspace mutations that produces a
// log and a final workspace.
package session

import (
	"fmt"
	"strconv"
	"strings"
)

// Op is the kind of a session step.
type Op uint8

// Session step kinds.
const (
	OpBuild Op = iota
	OpCreate
	OpEdit
	OpDelete
	OpTouch
	OpClean
)

// Step is one step of a session script.
type Step struct {
	Op      Op
	Path    string   // create, edit, delete, touch
	Targets []string // build: targets as written (may be empty)
	Workers int      // build: worker count, 1 when -j is absent
	Content []byte   // create, edit: the new content
}

// Script is a parsed session.
type Script struct {
	Steps []Step
}

// Parse parses the text of a session.txt file.
func Parse(src []byte) (*Script, error) {
	lines := strings.Split(string(src), "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	sc := &Script{}
	for i := 0; i < len(lines); i++ {
		line := strings.Trim(lines[i], " \t")
		if line == "" || line[0] == '#' {
			continue
		}
		words := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' })
		switch words[0] {
		case "build":
			st := Step{Op: OpBuild, Workers: 1}
			args := words[1:]
			if n := len(args); n >= 2 && args[n-2] == "-j" {
				w, err := strconv.Atoi(args[n-1])
				if err != nil || w < 1 {
					return nil, fmt.Errorf("session line %d: bad worker count %q", i+1, args[n-1])
				}
				st.Workers = w
				args = args[:n-2]
			}
			if len(args) > 0 {
				st.Targets = args
			}
			sc.Steps = append(sc.Steps, st)
		case "create", "edit":
			if len(words) != 2 {
				return nil, fmt.Errorf("session line %d: %s needs exactly one path", i+1, words[0])
			}
			st := Step{Op: OpCreate, Path: words[1]}
			if words[0] == "edit" {
				st.Op = OpEdit
			}
			var content []byte
			closed := false
			for i++; i < len(lines); i++ {
				if lines[i] == "---" {
					closed = true
					break
				}
				content = append(content, lines[i]...)
				content = append(content, '\n')
			}
			if !closed {
				return nil, fmt.Errorf("session: unterminated %s block for %s", words[0], words[1])
			}
			st.Content = content
			sc.Steps = append(sc.Steps, st)
		case "delete", "touch":
			if len(words) != 2 {
				return nil, fmt.Errorf("session line %d: %s needs exactly one path", i+1, words[0])
			}
			op := OpDelete
			if words[0] == "touch" {
				op = OpTouch
			}
			sc.Steps = append(sc.Steps, Step{Op: op, Path: words[1]})
		case "clean":
			if len(words) != 1 {
				return nil, fmt.Errorf("session line %d: clean takes no arguments", i+1)
			}
			sc.Steps = append(sc.Steps, Step{Op: OpClean})
		default:
			return nil, fmt.Errorf("session line %d: unknown step %q", i+1, words[0])
		}
	}
	return sc, nil
}
