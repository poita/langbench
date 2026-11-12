package scheme

import (
	"bufio"
	"io"
)

// Interp is an interpreter instance: a global environment plus an output
// stream. An Interp is not safe for concurrent use.
type Interp struct {
	global *Env
	out    *bufio.Writer
}

// New returns an interpreter whose display, newline and top-level results
// are written to out. The global environment contains the standard
// primitives.
func New(out io.Writer) *Interp {
	in := &Interp{global: newGlobalEnv(), out: bufio.NewWriterSize(out, 64*1024)}
	in.installBuiltins()
	return in
}

func (in *Interp) writeOut(b []byte) { in.out.Write(b) }

// Define binds name to v in the global environment.
func (in *Interp) Define(name string, v Value) { in.global.global[Intern(name)] = v }

// Lookup returns the global binding of name.
func (in *Interp) Lookup(name string) (Value, bool) {
	v, ok := in.global.global[Intern(name)]
	return v, ok
}

// Run reads src and evaluates its top-level forms in order, writing the
// write form and a newline for every value that is not void. It stops at the
// first error, returning an *Error (runtime) or *SyntaxError. Output produced
// before the error is flushed to the underlying writer; nothing is written
// for the error itself.
func (in *Interp) Run(src string) error {
	_, err := in.run(src, true)
	return err
}

// Eval evaluates the forms in src and returns the value of the last one
// (Void if there are none). Results are not printed; display and newline
// still write to the output.
func (in *Interp) Eval(src string) (Value, error) {
	return in.run(src, false)
}

func (in *Interp) run(src string, print bool) (last Value, err error) {
	defer in.out.Flush()
	defer func() {
		if p := recover(); p != nil {
			switch e := p.(type) {
			case *Error:
				err = e
			case *SyntaxError:
				err = e
			default:
				panic(p)
			}
		}
	}()
	last = Unspecified
	r := NewReader(src)
	for {
		form, rerr := r.Next()
		if rerr == io.EOF {
			return last, nil
		}
		if rerr != nil {
			return last, rerr
		}
		last = in.eval(analyze(form), in.global)
		if print && last != Unspecified {
			in.writeOut(appendValue(nil, last, false))
			in.writeOut([]byte{'\n'})
		}
	}
}

// Call applies the procedure f to args and returns its result.
func (in *Interp) Call(f Value, args ...Value) (v Value, err error) {
	defer in.out.Flush()
	defer func() {
		if p := recover(); p != nil {
			e, ok := p.(*Error)
			if !ok {
				panic(p)
			}
			err = e
		}
	}()
	return in.apply(f, append([]Value(nil), args...)), nil
}

// apply calls f on args by evaluating a synthetic application node.
func (in *Interp) apply(f Value, args []Value) Value {
	call := &callNode{fn: &constNode{f}, args: make([]node, len(args))}
	for i, a := range args {
		call.args[i] = &constNode{a}
	}
	return in.eval(call, in.global)
}
