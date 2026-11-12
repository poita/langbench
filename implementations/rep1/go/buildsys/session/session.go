// Package session parses and runs session scripts: scripted sequences of
// builds and workspace mutations that produce a log.
package session

import (
	"fmt"
	"strconv"
	"strings"

	"buildsys/engine"
	"buildsys/sched"
	"buildsys/vfs"
)

// Kind is the kind of a session step.
type Kind uint8

// Session step kinds.
const (
	Build Kind = iota
	Create
	Edit
	Delete
	Touch
	Clean
)

// Step is one session step.
type Step struct {
	Kind    Kind
	Path    string   // create, edit, delete, touch
	Content string   // create, edit
	Targets []string // build
	Workers int      // build
}

// Parse reads a session script.
func Parse(script string) ([]Step, error) {
	lines := strings.Split(script, "\n")
	var steps []Step
	for i := 0; i < len(lines); i++ {
		line := strings.Trim(lines[i], " \t")
		if line == "" || line[0] == '#' {
			continue
		}
		words := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' })
		switch words[0] {
		case "build":
			st := Step{Kind: Build, Workers: 1, Targets: words[1:]}
			if n := len(words); n >= 3 && words[n-2] == "-j" {
				w, err := strconv.Atoi(words[n-1])
				if err != nil || w < 1 {
					return nil, fmt.Errorf("session line %d: bad worker count %q", i+1, words[n-1])
				}
				st.Workers, st.Targets = w, words[1:n-2]
			}
			steps = append(steps, st)
		case "create", "edit":
			if len(words) != 2 {
				return nil, fmt.Errorf("session line %d: %s takes one path", i+1, words[0])
			}
			st := Step{Kind: Create, Path: words[1]}
			if words[0] == "edit" {
				st.Kind = Edit
			}
			var b strings.Builder
			j := i + 1
			for ; j < len(lines) && lines[j] != "---"; j++ {
				b.WriteString(lines[j])
				b.WriteByte('\n')
			}
			if j >= len(lines) {
				return nil, fmt.Errorf("session line %d: unterminated %s block", i+1, words[0])
			}
			st.Content = b.String()
			steps = append(steps, st)
			i = j
		case "delete", "touch":
			if len(words) != 2 {
				return nil, fmt.Errorf("session line %d: %s takes one path", i+1, words[0])
			}
			k := Delete
			if words[0] == "touch" {
				k = Touch
			}
			steps = append(steps, Step{Kind: k, Path: words[1]})
		case "clean":
			steps = append(steps, Step{Kind: Clean})
		default:
			return nil, fmt.Errorf("session line %d: unknown step %q", i+1, words[0])
		}
	}
	return steps, nil
}

// Run executes the steps against fs and returns the session log.
func Run(fs *vfs.FS, steps []Step) string {
	var log strings.Builder
	for i, st := range steps {
		fmt.Fprintf(&log, "step %d: ", i+1)
		switch st.Kind {
		case Build:
			runBuild(&log, fs, st)
		case Create, Edit:
			verb := "create"
			if st.Kind == Edit {
				verb = "edit"
			}
			fmt.Fprintf(&log, "%s %s\n", verb, st.Path)
			fs.Write(st.Path, st.Content)
			fmt.Fprintf(&log, "  ok size=%d\n", len(st.Content))
		case Delete:
			fmt.Fprintf(&log, "delete %s\n", st.Path)
			fs.Delete(st.Path)
			log.WriteString("  ok\n")
		case Touch:
			fmt.Fprintf(&log, "touch %s\n", st.Path)
			fs.Touch(st.Path)
			log.WriteString("  ok\n")
		case Clean:
			log.WriteString("clean\n")
			removed := fs.Generated()
			for _, p := range removed {
				fmt.Fprintf(&log, "  remove %s\n", p)
				fs.Delete(p)
			}
			fmt.Fprintf(&log, "  ok removed=%d\n", len(removed))
		}
	}
	return log.String()
}

func runBuild(log *strings.Builder, fs *vfs.FS, st Step) {
	targets := "(default)"
	if len(st.Targets) > 0 {
		targets = strings.Join(st.Targets, " ")
	}
	fmt.Fprintf(log, "build %s -j %d\n", targets, st.Workers)
	res := engine.Build(fs, st.Targets, st.Workers)
	for _, e := range res.Events {
		if e.Kind == sched.EvHit {
			fmt.Fprintf(log, "  hit %d %s\n", e.Start, e.Target)
		} else {
			fmt.Fprintf(log, "  %s %d %d w%d %s %s\n", e.Kind, e.Start, e.End, e.Worker, e.Target, e.Command)
		}
	}
	if res.Err != nil {
		fmt.Fprintf(log, "  error %s\n", res.Err)
		return
	}
	fmt.Fprintf(log, "  ok ran=%d hit=%d time=%d\n", res.Ran, res.Hits, res.Time)
}

// RunScript parses and runs a script, returning the log.
func RunScript(fs *vfs.FS, script string) (string, error) {
	steps, err := Parse(script)
	if err != nil {
		return "", err
	}
	return Run(fs, steps), nil
}
