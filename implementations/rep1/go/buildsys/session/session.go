// Package session parses session scripts (session.txt) and drives a whole
// session: a sequence of builds and workspace mutations against one virtual
// file system, producing the session log.
package session

import (
	"bytes"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"buildsys/build"
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
	Kind    Kind
	Path    string   // create, edit, delete, touch
	Content []byte   // create, edit
	Targets []string // build, as written
	Workers int      // build; 1 when -j is absent
}

// ParseError describes a malformed session script.
type ParseError struct {
	Line int
	Msg  string
}

func (e *ParseError) Error() string { return fmt.Sprintf("session.txt:%d: %s", e.Line, e.Msg) }

func isBlank(s string) bool { return strings.Trim(s, " \t") == "" }

// Parse parses a session script.
func Parse(script []byte) ([]Step, error) {
	lines := strings.Split(string(script), "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	var steps []Step
	for i := 0; i < len(lines); i++ {
		raw := lines[i]
		if isBlank(raw) || strings.HasPrefix(strings.TrimLeft(raw, " \t"), "#") {
			continue
		}
		words := strings.FieldsFunc(raw, func(r rune) bool { return r == ' ' || r == '\t' })
		bad := func(msg string) error { return &ParseError{Line: i + 1, Msg: msg} }
		switch words[0] {
		case "build":
			st := Step{Kind: Build, Workers: 1}
			targets := words[1:]
			if n := len(targets); n >= 2 && targets[n-2] == "-j" {
				w, err := strconv.Atoi(targets[n-1])
				if err != nil || w < 1 {
					return nil, bad("bad -j value " + targets[n-1])
				}
				st.Workers = w
				targets = targets[:n-2]
			}
			if len(targets) > 0 {
				st.Targets = targets
			}
			steps = append(steps, st)
		case "create", "edit":
			if len(words) != 2 {
				return nil, bad(words[0] + " takes exactly one path")
			}
			st := Step{Kind: Create, Path: words[1]}
			if words[0] == "edit" {
				st.Kind = Edit
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
				return nil, bad("unterminated content block")
			}
			st.Content = content
			steps = append(steps, st)
		case "delete", "touch":
			if len(words) != 2 {
				return nil, bad(words[0] + " takes exactly one path")
			}
			k := Delete
			if words[0] == "touch" {
				k = Touch
			}
			steps = append(steps, Step{Kind: k, Path: words[1]})
		case "clean":
			if len(words) != 1 {
				return nil, bad("clean takes no arguments")
			}
			steps = append(steps, Step{Kind: Clean})
		default:
			return nil, bad("unknown step " + words[0])
		}
	}
	return steps, nil
}

// Run executes the session steps against fs and returns the session log.
func Run(fs *vfs.FS, steps []Step) []byte {
	var log bytes.Buffer
	for n, st := range steps {
		fmt.Fprintf(&log, "step %d: ", n+1)
		switch st.Kind {
		case Build:
			log.WriteString("build")
			if len(st.Targets) == 0 {
				log.WriteString(" (default)")
			}
			for _, t := range st.Targets {
				log.WriteByte(' ')
				log.WriteString(t)
			}
			fmt.Fprintf(&log, " -j %d\n", st.Workers)
			writeBuild(&log, build.Run(fs, st.Targets, st.Workers))
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
			var removed []string
			for _, p := range fs.Paths() {
				if vfs.IsGenerated(p) || p == vfs.StateFile {
					removed = append(removed, p)
				}
			}
			sort.Strings(removed)
			for _, p := range removed {
				fs.Delete(p)
				fmt.Fprintf(&log, "  remove %s\n", p)
			}
			fmt.Fprintf(&log, "  ok removed=%d\n", len(removed))
		}
	}
	return log.Bytes()
}

func writeBuild(log *bytes.Buffer, res *build.Result) {
	for _, e := range res.Events {
		switch e.Kind {
		case build.KindHit:
			fmt.Fprintf(log, "  hit %d %s\n", e.Start, e.Target)
		default:
			word := [...]string{"", "run", "fail", "cancel"}[e.Kind]
			fmt.Fprintf(log, "  %s %d %d w%d %s %s\n", word, e.Start, e.End, e.Worker, e.Target, e.Command)
		}
	}
	if res.Err != nil {
		fmt.Fprintf(log, "  error %s\n", res.Err.Error())
		return
	}
	fmt.Fprintf(log, "  ok ran=%d hit=%d time=%d\n", res.Ran, res.Hits, res.Time)
}
