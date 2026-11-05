// Package cmds defines Kiln's sixteen built-in commands: their signatures and
// shapes, their canonical rendering, and their execution against file
// contents.
package cmds

import (
	"strconv"
	"strings"

	"buildsys/diag"
)

// ArgKind is the type of a command argument.
type ArgKind uint8

// Argument kinds.
const (
	ArgStr ArgKind = iota
	ArgInt
)

// TypeName returns the KBL type token for k ("str" or "int").
func (k ArgKind) TypeName() string {
	if k == ArgInt {
		return "int"
	}
	return "str"
}

// Spec describes a command: its argument signature, how many file inputs it
// takes (MaxIn < 0 means "any number from MinIn up"), whether it requires a
// depfile, and its default cost.
type Spec struct {
	Name        string
	Args        []ArgKind
	MinIn       int
	MaxIn       int
	Depfile     bool
	DefaultCost int64
}

var specs = []*Spec{
	{"write", []ArgKind{ArgStr}, 0, 0, false, 1},
	{"copy", nil, 1, 1, false, 1},
	{"concat", nil, 1, -1, false, 2},
	{"upper", nil, 1, 1, false, 2},
	{"lower", nil, 1, 1, false, 2},
	{"grep", []ArgKind{ArgStr}, 1, 1, false, 3},
	{"replace", []ArgKind{ArgStr, ArgStr}, 1, 1, false, 3},
	{"sort_lines", nil, 1, 1, false, 4},
	{"reverse_lines", nil, 1, 1, false, 2},
	{"dedup", nil, 1, 1, false, 3},
	{"number", nil, 1, 1, false, 2},
	{"indent", []ArgKind{ArgInt}, 1, 1, false, 2},
	{"wrap", []ArgKind{ArgStr, ArgStr}, 1, 1, false, 1},
	{"count_lines", nil, 1, -1, false, 2},
	{"hash", nil, 1, -1, false, 3},
	{"preprocess", nil, 1, 1, true, 6},
}

var byName = func() map[string]*Spec {
	m := make(map[string]*Spec, len(specs))
	for _, s := range specs {
		m[s.Name] = s
	}
	return m
}()

// Lookup returns the spec of the named command, or nil.
func Lookup(name string) *Spec { return byName[name] }

// Names returns the names of all commands in specification order.
func Names() []string {
	out := make([]string, len(specs))
	for i, s := range specs {
		out[i] = s.Name
	}
	return out
}

// InputRange renders the accepted file-input count as "lo-hi", using "N" for
// an unbounded upper end.
func (s *Spec) InputRange() string {
	hi := "N"
	if s.MaxIn >= 0 {
		hi = strconv.Itoa(s.MaxIn)
	}
	return strconv.Itoa(s.MinIn) + "-" + hi
}

// CheckShape validates the number of file inputs and declared outputs and the
// presence of a depfile, in that order, returning an E_CMD_SHAPE error.
func (s *Spec) CheckShape(fileInputs, outputs int, hasDepfile bool) error {
	if fileInputs < s.MinIn || (s.MaxIn >= 0 && fileInputs > s.MaxIn) {
		return diag.New(diag.CmdShape, "%s: expected inputs %s, got %d", s.Name, s.InputRange(), fileInputs)
	}
	if outputs != 1 {
		return diag.New(diag.CmdShape, "%s: expected outputs 1, got %d", s.Name, outputs)
	}
	if s.Depfile && !hasDepfile {
		return diag.New(diag.CmdShape, "%s: depfile required", s.Name)
	}
	if !s.Depfile && hasDepfile {
		return diag.New(diag.CmdShape, "%s: depfile not allowed", s.Name)
	}
	return nil
}

// Arg is a command argument: a string or an integer.
type Arg struct {
	IsInt bool
	Int   int64
	Str   string
}

// Command is a command invocation: a spec plus its evaluated arguments.
type Command struct {
	Spec *Spec
	Args []Arg
}

// CheckArgs performs the command-specific argument checks (E_ARG).
func (c *Command) CheckArgs() error {
	switch c.Spec.Name {
	case "replace":
		if c.Args[0].Str == "" {
			return diag.New(diag.Arg, "cmd replace: empty pattern")
		}
	case "indent":
		if c.Args[0].Int < 0 {
			return diag.New(diag.Arg, "cmd indent: negative")
		}
	}
	return nil
}

// String renders the canonical command string, e.g. `write("hi\n")`.
func (c *Command) String() string {
	var b strings.Builder
	b.WriteString(c.Spec.Name)
	b.WriteByte('(')
	for i, a := range c.Args {
		if i > 0 {
			b.WriteString(", ")
		}
		if a.IsInt {
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
		switch c := s[i]; {
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
