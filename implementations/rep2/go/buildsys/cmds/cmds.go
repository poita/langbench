// Package cmds implements Kiln's sixteen built-in commands: their static
// descriptions (argument signature, input/output shape, default cost), their
// canonical rendering, and their execution against a virtual file system.
package cmds

import (
	"sort"
	"strconv"
	"strings"

	"buildsys/kerr"
	"buildsys/vfs"
)

// ArgKind is the type of a command argument.
type ArgKind uint8

const (
	// StrArg is a string argument.
	StrArg ArgKind = iota
	// IntArg is an integer argument.
	IntArg
)

// String returns the type token used in error messages.
func (k ArgKind) String() string {
	if k == IntArg {
		return "int"
	}
	return "str"
}

// Arg is one evaluated command argument.
type Arg struct {
	Kind ArgKind
	Str  string
	Int  int64
}

// Invocation is a command name together with its evaluated arguments.
type Invocation struct {
	Name string
	Args []Arg
}

// Spec statically describes a command.
type Spec struct {
	Name string
	// Params lists the argument types.
	Params []ArgKind
	// MinInputs and MaxInputs bound the number of file inputs; MaxInputs < 0
	// means unbounded.
	MinInputs, MaxInputs int
	// Depfile reports whether the command requires (and only allows) a depfile.
	Depfile bool
	// DefaultCost is the cost used when a step has no cost field.
	DefaultCost int64

	run func(inv Invocation, in []Input, r Reader) (Result, *kerr.Error)
}

// Lookup returns the spec of the named command.
func Lookup(name string) (*Spec, bool) {
	s, ok := table[name]
	return s, ok
}

// Names returns the names of all commands, sorted.
func Names() []string {
	out := make([]string, 0, len(table))
	for n := range table {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// InputRange renders the accepted file-input count as "lo-hi" ("1-N" when
// unbounded), as used in E_CMD_SHAPE messages.
func (s *Spec) InputRange() string {
	if s.MaxInputs < 0 {
		return strconv.Itoa(s.MinInputs) + "-N"
	}
	return strconv.Itoa(s.MinInputs) + "-" + strconv.Itoa(s.MaxInputs)
}

// CheckArgs performs the command-specific argument checks (E_ARG).
func (s *Spec) CheckArgs(inv Invocation) *kerr.Error {
	switch s.Name {
	case "replace":
		if inv.Args[0].Str == "" {
			return kerr.New(kerr.Arg, "cmd replace: empty pattern")
		}
	case "indent":
		if inv.Args[0].Int < 0 {
			return kerr.New(kerr.Arg, "cmd indent: negative")
		}
	}
	return nil
}

// String renders the invocation in canonical form, e.g. `write("hi\n")`.
func (inv Invocation) String() string {
	var b strings.Builder
	b.WriteString(inv.Name)
	b.WriteByte('(')
	for i, a := range inv.Args {
		if i > 0 {
			b.WriteString(", ")
		}
		if a.Kind == IntArg {
			b.WriteString(strconv.FormatInt(a.Int, 10))
		} else {
			quote(&b, a.Str)
		}
	}
	b.WriteByte(')')
	return b.String()
}

func quote(b *strings.Builder, s string) {
	const hex = "0123456789abcdef"
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\':
			b.WriteString(`\\`)
		case c == '"':
			b.WriteString(`\"`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\t':
			b.WriteString(`\t`)
		case c == '\r':
			b.WriteString(`\r`)
		case c < 0x20 || c == 0x7f:
			b.WriteString(`\x`)
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&15])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
}

// Input is a file input of a command, captured at the command's start time.
type Input struct {
	Path string
	File *vfs.File
}

// Reader gives a command access to workspace files other than its declared
// inputs (preprocess uses it to follow @need directives).
type Reader interface {
	Get(path string) *vfs.File
}

// Dep is a discovered dependency together with the file snapshot read.
type Dep struct {
	Path string
	File *vfs.File
}

// Result is what a successful command produces.
type Result struct {
	// Output is the content of the declared output.
	Output string
	// Depfile is the content of the depfile, if the command has one.
	Depfile string
	// Deps are the discovered dependencies, sorted by path.
	Deps []Dep
}

// Run executes the command. All reads happen inside Run; the caller applies
// the result later.
func (s *Spec) Run(inv Invocation, in []Input, r Reader) (Result, *kerr.Error) {
	return s.run(inv, in, r)
}

// SplitLines returns the lines of c: split at every LF, dropping a final empty
// piece; empty content has no lines.
func SplitLines(c string) []string {
	if c == "" {
		return nil
	}
	lines := strings.Split(c, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// JoinLines renders lines, each followed by a newline.
func JoinLines(lines []string) string {
	n := 0
	for _, l := range lines {
		n += len(l) + 1
	}
	var b strings.Builder
	b.Grow(n)
	for _, l := range lines {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return b.String()
}

var table = map[string]*Spec{}

func register(s *Spec) { table[s.Name] = s }

func lineCmd(name string, params []ArgKind, cost int64, f func(lines []string, inv Invocation) []string) {
	register(&Spec{
		Name: name, Params: params, MinInputs: 1, MaxInputs: 1, DefaultCost: cost,
		run: func(inv Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			return Result{Output: JoinLines(f(SplitLines(in[0].File.Content()), inv))}, nil
		},
	})
}

func init() {
	str, num := StrArg, IntArg
	register(&Spec{Name: "write", Params: []ArgKind{str}, MinInputs: 0, MaxInputs: 0, DefaultCost: 1,
		run: func(inv Invocation, _ []Input, _ Reader) (Result, *kerr.Error) {
			return Result{Output: inv.Args[0].Str}, nil
		}})
	register(&Spec{Name: "copy", MinInputs: 1, MaxInputs: 1, DefaultCost: 1,
		run: func(_ Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			return Result{Output: in[0].File.Content()}, nil
		}})
	register(&Spec{Name: "concat", MinInputs: 1, MaxInputs: -1, DefaultCost: 2,
		run: func(_ Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			var b strings.Builder
			for _, f := range in {
				b.WriteString(f.File.Content())
			}
			return Result{Output: b.String()}, nil
		}})
	register(&Spec{Name: "upper", MinInputs: 1, MaxInputs: 1, DefaultCost: 2,
		run: func(_ Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			return Result{Output: asciiMap(in[0].File.Content(), 'a', 'z', -32)}, nil
		}})
	register(&Spec{Name: "lower", MinInputs: 1, MaxInputs: 1, DefaultCost: 2,
		run: func(_ Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			return Result{Output: asciiMap(in[0].File.Content(), 'A', 'Z', 32)}, nil
		}})
	lineCmd("grep", []ArgKind{str}, 3, func(lines []string, inv Invocation) []string {
		var out []string
		for _, l := range lines {
			if strings.Contains(l, inv.Args[0].Str) {
				out = append(out, l)
			}
		}
		return out
	})
	register(&Spec{Name: "replace", Params: []ArgKind{str, str}, MinInputs: 1, MaxInputs: 1, DefaultCost: 3,
		run: func(inv Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			return Result{Output: strings.ReplaceAll(in[0].File.Content(), inv.Args[0].Str, inv.Args[1].Str)}, nil
		}})
	lineCmd("sort_lines", nil, 4, func(lines []string, _ Invocation) []string {
		out := append([]string(nil), lines...)
		sort.Strings(out)
		return out
	})
	lineCmd("reverse_lines", nil, 2, func(lines []string, _ Invocation) []string {
		out := make([]string, len(lines))
		for i, l := range lines {
			out[len(lines)-1-i] = l
		}
		return out
	})
	lineCmd("dedup", nil, 3, func(lines []string, _ Invocation) []string {
		seen := make(map[string]struct{}, len(lines))
		var out []string
		for _, l := range lines {
			if _, ok := seen[l]; ok {
				continue
			}
			seen[l] = struct{}{}
			out = append(out, l)
		}
		return out
	})
	lineCmd("number", nil, 2, func(lines []string, _ Invocation) []string {
		out := make([]string, len(lines))
		for i, l := range lines {
			out[i] = strconv.Itoa(i+1) + ": " + l
		}
		return out
	})
	lineCmd("indent", []ArgKind{num}, 2, func(lines []string, inv Invocation) []string {
		pad := strings.Repeat(" ", int(inv.Args[0].Int))
		out := make([]string, len(lines))
		for i, l := range lines {
			out[i] = pad + l
		}
		return out
	})
	register(&Spec{Name: "wrap", Params: []ArgKind{str, str}, MinInputs: 1, MaxInputs: 1, DefaultCost: 1,
		run: func(inv Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			return Result{Output: inv.Args[0].Str + in[0].File.Content() + inv.Args[1].Str}, nil
		}})
	register(&Spec{Name: "count_lines", MinInputs: 1, MaxInputs: -1, DefaultCost: 2,
		run: func(_ Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			var b strings.Builder
			total := 0
			for _, f := range in {
				n := len(SplitLines(f.File.Content()))
				total += n
				b.WriteString(strconv.Itoa(n) + " " + f.Path + "\n")
			}
			b.WriteString(strconv.Itoa(total) + " total\n")
			return Result{Output: b.String()}, nil
		}})
	register(&Spec{Name: "hash", MinInputs: 1, MaxInputs: -1, DefaultCost: 3,
		run: func(_ Invocation, in []Input, _ Reader) (Result, *kerr.Error) {
			var b strings.Builder
			for _, f := range in {
				b.WriteString(vfs.HashString(f.File.Hash()) + " " + f.Path + "\n")
			}
			return Result{Output: b.String()}, nil
		}})
	register(&Spec{Name: "preprocess", MinInputs: 1, MaxInputs: 1, Depfile: true, DefaultCost: 6, run: runPreprocess})
}

func asciiMap(s string, lo, hi byte, delta int) string {
	var b []byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= lo && c <= hi {
			if b == nil {
				b = []byte(s)
			}
			b[i] = byte(int(c) + delta)
		}
	}
	if b == nil {
		return s
	}
	return string(b)
}

const needPrefix = "@need "

func runPreprocess(_ Invocation, in []Input, r Reader) (Result, *kerr.Error) {
	var out strings.Builder
	onStack := map[string]bool{in[0].Path: true}
	found := map[string]*vfs.File{}

	var expand func(path, content string) *kerr.Error
	expand = func(path, content string) *kerr.Error {
		for _, line := range SplitLines(content) {
			if len(line) > len(needPrefix) && strings.HasPrefix(line, needPrefix) {
				q := line[len(needPrefix):]
				if !vfs.ValidPath(q) {
					return kerr.New(kerr.NeedPath, "%s", q)
				}
				f := r.Get(q)
				if f == nil {
					return kerr.New(kerr.NeedMissing, "%s needed by %s", q, path)
				}
				if onStack[q] {
					return kerr.New(kerr.NeedCycle, "%s", q)
				}
				found[q] = f
				onStack[q] = true
				if err := expand(q, f.Content()); err != nil {
					return err
				}
				delete(onStack, q)
				continue
			}
			out.WriteString(line)
			out.WriteByte('\n')
		}
		return nil
	}
	if err := expand(in[0].Path, in[0].File.Content()); err != nil {
		return Result{}, err
	}
	deps := make([]Dep, 0, len(found))
	for p, f := range found {
		deps = append(deps, Dep{Path: p, File: f})
	}
	sort.Slice(deps, func(i, j int) bool { return deps[i].Path < deps[j].Path })
	var d strings.Builder
	d.WriteString("kiln-deps 1\n")
	for _, dep := range deps {
		d.WriteString("need " + dep.Path + "\n")
	}
	return Result{Output: out.String(), Depfile: d.String(), Deps: deps}, nil
}
