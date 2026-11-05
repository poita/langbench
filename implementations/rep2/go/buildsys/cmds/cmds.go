// Package cmds implements Kiln's sixteen built-in commands: their static
// signatures (arguments, input and output counts, default cost) and their
// pure, in-process execution over byte strings.
package cmds

import (
	"strconv"

	"kiln/errs"
	"kiln/vfs"
)

// ArgKind is the type of a command argument.
type ArgKind uint8

// Argument kinds.
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

// Arg is one command argument value.
type Arg struct {
	Kind ArgKind
	S    string
	I    int64
}

// StrArg and IntArg build arguments.
func StrArg(s string) Arg { return Arg{Kind: Str, S: s} }

// IntArg builds an integer argument.
func IntArg(i int64) Arg { return Arg{Kind: Int, I: i} }

// Unbounded is the MaxIn value of commands that accept any number (>= MinIn)
// of file inputs.
const Unbounded = -1

// Spec describes one command.
type Spec struct {
	Name        string
	Params      []ArgKind
	MinIn       int
	MaxIn       int // Unbounded for "1 or more"
	Depfile     bool
	DefaultCost int64
	run         func(a []Arg, in []Input, src Source) (Result, *errs.Error)
}

// InputRange renders the accepted file-input count as "lo-hi".
func (s *Spec) InputRange() string {
	if s.MaxIn == Unbounded {
		return strconv.Itoa(s.MinIn) + "-N"
	}
	return strconv.Itoa(s.MinIn) + "-" + strconv.Itoa(s.MaxIn)
}

// CheckArgs performs the command-specific argument checks that happen when a
// step is validated (an empty replace pattern, a negative indent).
func (s *Spec) CheckArgs(a []Arg) *errs.Error {
	switch s.Name {
	case "replace":
		if a[0].S == "" {
			return errs.New(errs.Arg, "cmd replace: empty pattern")
		}
	case "indent":
		if a[0].I < 0 {
			return errs.New(errs.Arg, "cmd indent: negative")
		}
	}
	return nil
}

// Input is the content of one file input, captured when the command starts.
type Input struct {
	Path string
	Data []byte
	Hash uint64
}

// Source gives commands read access to workspace files (used by preprocess
// to follow @need directives).
type Source interface {
	Lookup(path string) (data []byte, hash uint64, ok bool)
}

// Dep is a discovered dependency: a file read, with the hash of what was read.
type Dep struct {
	Path string
	Hash uint64
}

// Result is what a command produces. Output is the content of the declared
// output; Depfile is the content of the depfile (nil unless the command uses
// one); Deps are the discovered dependencies sorted by path.
type Result struct {
	Output  []byte
	Depfile []byte
	Deps    []Dep
}

// Run executes the command over its captured inputs. Errors are execution
// errors (only preprocess can raise them).
func (s *Spec) Run(args []Arg, in []Input, src Source) (Result, *errs.Error) {
	return s.run(args, in, src)
}

var table = map[string]*Spec{}

// Lookup returns the command with the given name.
func Lookup(name string) (*Spec, bool) {
	s, ok := table[name]
	return s, ok
}

// Names returns the names of all commands in the order of the specification.
func Names() []string {
	out := make([]string, len(order))
	copy(out, order)
	return out
}

var order []string

func register(s *Spec) {
	table[s.Name] = s
	order = append(order, s.Name)
}

// Render returns the canonical string for a command invocation:
// name(arg, arg, ...), with strings quoted and escaped.
func Render(name string, args []Arg) string {
	b := make([]byte, 0, 32)
	b = append(b, name...)
	b = append(b, '(')
	for i, a := range args {
		if i > 0 {
			b = append(b, ',', ' ')
		}
		if a.Kind == Int {
			b = strconv.AppendInt(b, a.I, 10)
		} else {
			b = appendQuoted(b, a.S)
		}
	}
	b = append(b, ')')
	return string(b)
}

const hexDigits = "0123456789abcdef"

func appendQuoted(b []byte, s string) []byte {
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\':
			b = append(b, '\\', '\\')
		case c == '"':
			b = append(b, '\\', '"')
		case c == '\n':
			b = append(b, '\\', 'n')
		case c == '\t':
			b = append(b, '\\', 't')
		case c == '\r':
			b = append(b, '\\', 'r')
		case c < 0x20 || c == 0x7f:
			b = append(b, '\\', 'x', hexDigits[c>>4], hexDigits[c&15])
		default:
			b = append(b, c)
		}
	}
	return append(b, '"')
}

// HashLine formats "<hash> <path>\n" as used by the hash command.
func hashLine(b []byte, h uint64, path string) []byte {
	b = append(b, vfs.HashHex(h)...)
	b = append(b, ' ')
	b = append(b, path...)
	return append(b, '\n')
}
