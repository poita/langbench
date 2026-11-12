// Package session runs Kiln sessions: scripted sequences of builds and
// workspace mutations, producing a deterministic textual log.
package session

import (
	"fmt"
	"strconv"
	"strings"

	"buildsys"
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

// Step is one parsed session step.
type Step struct {
	Kind Kind
	// Targets and Workers are set for Build steps; Targets are the words
	// exactly as written.
	Targets []string
	Workers int
	// Path is set for Create, Edit, Delete and Touch.
	Path string
	// Content is the new content for Create and Edit.
	Content string
}

// Parse parses the text of a session script.
func Parse(text string) ([]Step, error) {
	lines := strings.Split(text, "\n")
	var steps []Step
	for i := 0; i < len(lines); i++ {
		trimmed := strings.Trim(lines[i], " \t")
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		words := strings.FieldsFunc(trimmed, func(r rune) bool { return r == ' ' || r == '\t' })
		switch words[0] {
		case "build":
			st := Step{Kind: Build, Workers: 1, Targets: words[1:]}
			if n := len(words); n >= 3 && words[n-2] == "-j" {
				w, err := strconv.Atoi(words[n-1])
				if err != nil {
					return nil, fmt.Errorf("session line %d: bad worker count %q", i+1, words[n-1])
				}
				st.Workers, st.Targets = w, words[1:n-2]
			}
			steps = append(steps, st)
		case "create", "edit":
			if len(words) != 2 {
				return nil, fmt.Errorf("session line %d: %s needs one path", i+1, words[0])
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
				return nil, fmt.Errorf("session line %d: %s needs one path", i+1, words[0])
			}
			st := Step{Kind: Delete, Path: words[1]}
			if words[0] == "touch" {
				st.Kind = Touch
			}
			steps = append(steps, st)
		case "clean":
			steps = append(steps, Step{Kind: Clean})
		default:
			return nil, fmt.Errorf("session line %d: unknown step %q", i+1, words[0])
		}
	}
	return steps, nil
}

// Run executes the steps against fs and returns the log.
func Run(fs *vfs.FS, steps []Step) string {
	var log strings.Builder
	for i, st := range steps {
		fmt.Fprintf(&log, "step %d: ", i+1)
		switch st.Kind {
		case Build:
			targets := "(default)"
			if len(st.Targets) > 0 {
				targets = strings.Join(st.Targets, " ")
			}
			fmt.Fprintf(&log, "build %s -j %d\n", targets, st.Workers)
			res := buildsys.Build(fs, buildsys.Options{Targets: st.Targets, Workers: st.Workers})
			writeBuild(&log, res)
		case Create, Edit:
			name := "create"
			if st.Kind == Edit {
				name = "edit"
			}
			fmt.Fprintf(&log, "%s %s\n", name, st.Path)
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
			removed := fs.Clean()
			for _, p := range removed {
				fmt.Fprintf(&log, "  remove %s\n", p)
			}
			fmt.Fprintf(&log, "  ok removed=%d\n", len(removed))
		}
	}
	return log.String()
}

// RunScript parses and runs a session script against fs.
func RunScript(fs *vfs.FS, script string) (string, error) {
	steps, err := Parse(script)
	if err != nil {
		return "", err
	}
	return Run(fs, steps), nil
}

func writeBuild(log *strings.Builder, res *buildsys.Result) {
	for _, ev := range res.Events {
		switch ev.Kind {
		case sched.KindHit:
			fmt.Fprintf(log, "  hit %d %s\n", ev.Start, ev.Target)
		default:
			word := [...]string{sched.KindRun: "run", sched.KindFail: "fail", sched.KindCancel: "cancel"}[ev.Kind]
			fmt.Fprintf(log, "  %s %d %d w%d %s %s\n", word, ev.Start, ev.End, ev.Worker, ev.Target, ev.Cmd)
		}
	}
	if res.Err != nil {
		fmt.Fprintf(log, "  error %s\n", res.Err.Error())
		return
	}
	fmt.Fprintf(log, "  ok ran=%d hit=%d time=%d\n", res.Ran, res.Hits, res.Time)
}
