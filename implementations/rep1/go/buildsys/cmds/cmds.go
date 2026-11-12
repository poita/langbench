// Package cmds implements Kiln's sixteen built-in commands: their signatures,
// shape constraints, canonical rendering and execution.
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

// Command argument kinds.
const (
	Str ArgKind = iota
	Int
)

// String returns the type token used in error messages.
func (k ArgKind) String() string {
	if k == Int {
		return "int"
	}
	return "str"
}

// Arg is an evaluated command argument.
type Arg struct {
	Kind ArgKind
	Str  string
	Int  int64
}

// StrArg and IntArg construct arguments.
func StrArg(s string) Arg { return Arg{Kind: Str, Str: s} }

// IntArg constructs an integer argument.
func IntArg(i int64) Arg { return Arg{Kind: Int, Int: i} }

// Spec describes a command.
type Spec struct {
	Name        string
	Params      []ArgKind
	MinIn       int // minimum number of file inputs
	MaxIn       int // maximum number of file inputs; -1 means unbounded
	Depfile     bool
	DefaultCost int
}

var specList = []*Spec{
	{"write", []ArgKind{Str}, 0, 0, false, 1},
	{"copy", nil, 1, 1, false, 1},
	{"concat", nil, 1, -1, false, 2},
	{"upper", nil, 1, 1, false, 2},
	{"lower", nil, 1, 1, false, 2},
	{"grep", []ArgKind{Str}, 1, 1, false, 3},
	{"replace", []ArgKind{Str, Str}, 1, 1, false, 3},
	{"sort_lines", nil, 1, 1, false, 4},
	{"reverse_lines", nil, 1, 1, false, 2},
	{"dedup", nil, 1, 1, false, 3},
	{"number", nil, 1, 1, false, 2},
	{"indent", []ArgKind{Int}, 1, 1, false, 2},
	{"wrap", []ArgKind{Str, Str}, 1, 1, false, 1},
	{"count_lines", nil, 1, -1, false, 2},
	{"hash", nil, 1, -1, false, 3},
	{"preprocess", nil, 1, 1, true, 6},
}

var specs = func() map[string]*Spec {
	m := make(map[string]*Spec, len(specList))
	for _, s := range specList {
		m[s.Name] = s
	}
	return m
}()

// Lookup returns the command with the given name.
func Lookup(name string) (*Spec, bool) {
	s, ok := specs[name]
	return s, ok
}

// InputRange renders the accepted input count as "lo-hi" ("1-N" if unbounded).
func (s *Spec) InputRange() string {
	hi := "N"
	if s.MaxIn >= 0 {
		hi = strconv.Itoa(s.MaxIn)
	}
	return strconv.Itoa(s.MinIn) + "-" + hi
}

// CheckShape checks the number of file inputs and declared outputs and the
// presence of a depfile, in the order the specification fixes.
func (s *Spec) CheckShape(fileInputs, outputs int, hasDepfile bool) error {
	if fileInputs < s.MinIn || (s.MaxIn >= 0 && fileInputs > s.MaxIn) {
		return kerr.New(kerr.CmdShape, "%s: expected inputs %s, got %d", s.Name, s.InputRange(), fileInputs)
	}
	if outputs != 1 {
		return kerr.New(kerr.CmdShape, "%s: expected outputs 1, got %d", s.Name, outputs)
	}
	if s.Depfile && !hasDepfile {
		return kerr.New(kerr.CmdShape, "%s: depfile required", s.Name)
	}
	if !s.Depfile && hasDepfile {
		return kerr.New(kerr.CmdShape, "%s: depfile not allowed", s.Name)
	}
	return nil
}

// CheckArgs performs the command-specific argument checks.
func (s *Spec) CheckArgs(args []Arg) error {
	switch s.Name {
	case "replace":
		if args[0].Str == "" {
			return kerr.New(kerr.Arg, "cmd replace: empty pattern")
		}
	case "indent":
		if args[0].Int < 0 {
			return kerr.New(kerr.Arg, "cmd indent: negative")
		}
	}
	return nil
}

// Render returns the canonical command string, e.g. `grep("x")`.
func Render(name string, args []Arg) string {
	var b strings.Builder
	b.WriteString(name)
	b.WriteByte('(')
	for i, a := range args {
		if i > 0 {
			b.WriteString(", ")
		}
		if a.Kind == Int {
			b.WriteString(strconv.FormatInt(a.Int, 10))
		} else {
			writeQuoted(&b, a.Str)
		}
	}
	b.WriteByte(')')
	return b.String()
}

func writeQuoted(b *strings.Builder, s string) {
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
			b.WriteByte(hex[c&0xf])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
}

// Files is the read-only view of the workspace a command needs.
type Files interface {
	Read(path string) (string, bool)
	Hash(path string) (string, bool)
}

// Result is what a successful command produces.
type Result struct {
	Out        string   // content of the declared output
	Depfile    string   // content of the depfile (preprocess only)
	Discovered []string // sorted discovered dependencies (preprocess only)
}

// Lines splits content into lines as the specification defines them.
func Lines(c string) []string {
	if c == "" {
		return nil
	}
	ls := strings.Split(c, "\n")
	if ls[len(ls)-1] == "" {
		ls = ls[:len(ls)-1]
	}
	return ls
}

func joinLines(ls []string) string {
	n := 0
	for _, l := range ls {
		n += len(l) + 1
	}
	var b strings.Builder
	b.Grow(n)
	for _, l := range ls {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return b.String()
}

// ReplaceAll replaces every non-overlapping occurrence of from (scanning left
// to right) with to. from must be non-empty.
func ReplaceAll(s, from, to string) string {
	return strings.ReplaceAll(s, from, to)
}

func mapASCII(s string, lowerToUpper bool) string {
	b := []byte(s)
	for i, c := range b {
		if lowerToUpper {
			if c >= 'a' && c <= 'z' {
				b[i] = c - 32
			}
		} else if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// Run executes a command over the given file inputs (workspace paths, in
// declared order). The only errors it returns are the preprocess execution
// errors.
func Run(spec *Spec, args []Arg, inputs []string, fs Files) (Result, error) {
	read := func(p string) string { c, _ := fs.Read(p); return c }
	switch spec.Name {
	case "write":
		return Result{Out: args[0].Str}, nil
	case "copy":
		return Result{Out: read(inputs[0])}, nil
	case "concat":
		var b strings.Builder
		for _, p := range inputs {
			b.WriteString(read(p))
		}
		return Result{Out: b.String()}, nil
	case "upper":
		return Result{Out: mapASCII(read(inputs[0]), true)}, nil
	case "lower":
		return Result{Out: mapASCII(read(inputs[0]), false)}, nil
	case "grep":
		var out []string
		for _, l := range Lines(read(inputs[0])) {
			if strings.Contains(l, args[0].Str) {
				out = append(out, l)
			}
		}
		return Result{Out: joinLines(out)}, nil
	case "replace":
		return Result{Out: ReplaceAll(read(inputs[0]), args[0].Str, args[1].Str)}, nil
	case "sort_lines":
		ls := Lines(read(inputs[0]))
		sort.Strings(ls)
		return Result{Out: joinLines(ls)}, nil
	case "reverse_lines":
		ls := Lines(read(inputs[0]))
		for i, j := 0, len(ls)-1; i < j; i, j = i+1, j-1 {
			ls[i], ls[j] = ls[j], ls[i]
		}
		return Result{Out: joinLines(ls)}, nil
	case "dedup":
		seen := make(map[string]struct{})
		var out []string
		for _, l := range Lines(read(inputs[0])) {
			if _, dup := seen[l]; !dup {
				seen[l] = struct{}{}
				out = append(out, l)
			}
		}
		return Result{Out: joinLines(out)}, nil
	case "number":
		ls := Lines(read(inputs[0]))
		var b strings.Builder
		for i, l := range ls {
			b.WriteString(strconv.Itoa(i + 1))
			b.WriteString(": ")
			b.WriteString(l)
			b.WriteByte('\n')
		}
		return Result{Out: b.String()}, nil
	case "indent":
		pad := strings.Repeat(" ", int(args[0].Int))
		var b strings.Builder
		for _, l := range Lines(read(inputs[0])) {
			b.WriteString(pad)
			b.WriteString(l)
			b.WriteByte('\n')
		}
		return Result{Out: b.String()}, nil
	case "wrap":
		return Result{Out: args[0].Str + read(inputs[0]) + args[1].Str}, nil
	case "count_lines":
		var b strings.Builder
		total := 0
		for _, p := range inputs {
			n := len(Lines(read(p)))
			total += n
			b.WriteString(strconv.Itoa(n))
			b.WriteByte(' ')
			b.WriteString(p)
			b.WriteByte('\n')
		}
		b.WriteString(strconv.Itoa(total))
		b.WriteString(" total\n")
		return Result{Out: b.String()}, nil
	case "hash":
		var b strings.Builder
		for _, p := range inputs {
			h, _ := fs.Hash(p)
			b.WriteString(h)
			b.WriteByte(' ')
			b.WriteString(p)
			b.WriteByte('\n')
		}
		return Result{Out: b.String()}, nil
	case "preprocess":
		return preprocess(inputs[0], fs)
	}
	panic("cmds: unhandled command " + spec.Name)
}

const needPrefix = "@need "

type expander struct {
	fs         Files
	stack      map[string]bool
	discovered map[string]struct{}
	out        []string
}

func (e *expander) expand(p string) error {
	e.stack[p] = true
	content, _ := e.fs.Read(p)
	for _, l := range Lines(content) {
		if strings.HasPrefix(l, needPrefix) && len(l) > len(needPrefix) {
			q := l[len(needPrefix):]
			if !vfs.ValidPath(q) {
				return kerr.New(kerr.NeedPath, "%s", q)
			}
			if _, ok := e.fs.Read(q); !ok {
				return kerr.New(kerr.NeedMissing, "%s needed by %s", q, p)
			}
			if e.stack[q] {
				return kerr.New(kerr.NeedCycle, "%s", q)
			}
			e.discovered[q] = struct{}{}
			if err := e.expand(q); err != nil {
				return err
			}
		} else {
			e.out = append(e.out, l)
		}
	}
	delete(e.stack, p)
	return nil
}

func preprocess(input string, fs Files) (Result, error) {
	e := &expander{fs: fs, stack: map[string]bool{}, discovered: map[string]struct{}{}}
	if err := e.expand(input); err != nil {
		return Result{}, err
	}
	found := make([]string, 0, len(e.discovered))
	for p := range e.discovered {
		found = append(found, p)
	}
	sort.Strings(found)
	var dep strings.Builder
	dep.WriteString("kiln-deps 1\n")
	for _, p := range found {
		dep.WriteString("need ")
		dep.WriteString(p)
		dep.WriteByte('\n')
	}
	return Result{Out: joinLines(e.out), Depfile: dep.String(), Discovered: found}, nil
}
