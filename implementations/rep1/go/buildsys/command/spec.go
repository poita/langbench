// Package command defines Kiln's sixteen built-in commands: their signatures,
// shape constraints and default costs, their canonical textual rendering, and
// their in-process execution against file contents.
package command

import (
	"strconv"
	"strings"
)

// ArgType is the type of a command argument.
type ArgType uint8

// Argument types.
const (
	StrArg ArgType = iota
	IntArg
)

// Name returns the type token used in error messages.
func (t ArgType) Name() string {
	if t == IntArg {
		return "int"
	}
	return "str"
}

// Arg is an evaluated command argument: either a string or an integer.
type Arg struct {
	IsInt bool
	Int   int64
	Str   string
}

// StrOf returns a string argument.
func StrOf(s string) Arg { return Arg{Str: s} }

// IntOf returns an integer argument.
func IntOf(n int64) Arg { return Arg{IsInt: true, Int: n} }

// Spec describes one command.
type Spec struct {
	Name        string
	Args        []ArgType
	MinIn       int // minimum number of file inputs
	MaxIn       int // maximum number of file inputs; -1 means unbounded
	Depfile     bool
	DefaultCost int64
}

// InputRange renders the accepted input count as written in E_CMD_SHAPE
// messages: "0-0", "1-1" or "1-N".
func (s *Spec) InputRange() string {
	hi := "N"
	if s.MaxIn >= 0 {
		hi = strconv.Itoa(s.MaxIn)
	}
	return strconv.Itoa(s.MinIn) + "-" + hi
}

// FitsInputs reports whether n file inputs are acceptable.
func (s *Spec) FitsInputs(n int) bool {
	return n >= s.MinIn && (s.MaxIn < 0 || n <= s.MaxIn)
}

var specs = map[string]*Spec{}

func def(name string, in int, max int, cost int64, args ...ArgType) {
	specs[name] = &Spec{Name: name, Args: args, MinIn: in, MaxIn: max, DefaultCost: cost}
}

func init() {
	def("write", 0, 0, 1, StrArg)
	def("copy", 1, 1, 1)
	def("concat", 1, -1, 2)
	def("upper", 1, 1, 2)
	def("lower", 1, 1, 2)
	def("grep", 1, 1, 3, StrArg)
	def("replace", 1, 1, 3, StrArg, StrArg)
	def("sort_lines", 1, 1, 4)
	def("reverse_lines", 1, 1, 2)
	def("dedup", 1, 1, 3)
	def("number", 1, 1, 2)
	def("indent", 1, 1, 2, IntArg)
	def("wrap", 1, 1, 1, StrArg, StrArg)
	def("count_lines", 1, -1, 2)
	def("hash", 1, -1, 3)
	def("preprocess", 1, 1, 6)
	specs["preprocess"].Depfile = true
}

// Lookup returns the spec of the named command.
func Lookup(name string) (*Spec, bool) {
	s, ok := specs[name]
	return s, ok
}

// Canonical renders a command invocation as `name(arg, arg, ...)`, the form
// used in the state file, the log and change detection.
func Canonical(name string, args []Arg) string {
	var b strings.Builder
	b.WriteString(name)
	b.WriteByte('(')
	for i, a := range args {
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
