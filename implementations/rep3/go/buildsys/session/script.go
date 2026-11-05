// Package session runs a Kiln session: a scripted sequence of builds and
// workspace mutations, producing the session log.
package session

import (
	"fmt"
	"strconv"
	"strings"
)

// StepKind is the kind of a session step.
type StepKind uint8

// Session step kinds.
const (
	StepBuild StepKind = iota
	StepCreate
	StepEdit
	StepDelete
	StepTouch
	StepClean
)

// Step is one parsed session step.
type Step struct {
	Kind StepKind
	// Targets and Jobs are set for builds; Jobs defaults to 1.
	Targets []string
	Jobs    int
	// Path is set for create, edit, delete and touch.
	Path string
	// Content is the new content for create and edit.
	Content []byte
}

// ParseScript parses session.txt.
func ParseScript(data []byte) ([]Step, error) {
	lines := strings.Split(string(data), "\n")
	var steps []Step
	for i := 0; i < len(lines); i++ {
		line := strings.Trim(lines[i], " \t")
		if line == "" || line[0] == '#' {
			continue
		}
		words := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' })
		switch words[0] {
		case "build":
			st := Step{Kind: StepBuild, Jobs: 1}
			args := words[1:]
			if n := len(args); n >= 2 && args[n-2] == "-j" {
				j, err := strconv.Atoi(args[n-1])
				if err != nil {
					return nil, fmt.Errorf("session line %d: bad -j value %q", i+1, args[n-1])
				}
				st.Jobs = j
				args = args[:n-2]
			}
			st.Targets = args
			steps = append(steps, st)
		case "create", "edit":
			if len(words) != 2 {
				return nil, fmt.Errorf("session line %d: %s needs one path", i+1, words[0])
			}
			st := Step{Kind: StepCreate, Path: words[1]}
			if words[0] == "edit" {
				st.Kind = StepEdit
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
				return nil, fmt.Errorf("session: unterminated %s block", words[0])
			}
			st.Content = content
			steps = append(steps, st)
		case "delete", "touch":
			if len(words) != 2 {
				return nil, fmt.Errorf("session line %d: %s needs one path", i+1, words[0])
			}
			kind := StepDelete
			if words[0] == "touch" {
				kind = StepTouch
			}
			steps = append(steps, Step{Kind: kind, Path: words[1]})
		case "clean":
			steps = append(steps, Step{Kind: StepClean})
		default:
			return nil, fmt.Errorf("session line %d: unknown step %q", i+1, words[0])
		}
	}
	return steps, nil
}
