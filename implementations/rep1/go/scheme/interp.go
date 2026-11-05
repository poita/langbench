package scheme

// Interp is an interpreter instance: a symbol table, a global environment
// and an output buffer. An Interp is not safe for concurrent use; create one
// per goroutine. State (global definitions) persists across Run/Eval calls.
type Interp struct {
	symIDs  map[string]int32
	symVals []Value // symbol id -> symbol Value
	globals []Value // symbol id -> global binding (tUnbound if none)
	stack   []Value // shared argument stack
	out     []byte  // output buffer
}

// Symbol ids of the special-form names; they are interned first, in this
// order, so recognising them is an integer comparison.
const (
	symQuote int32 = iota
	symIf
	symDefine
	symSet
	symLambda
	symLet
	symLetStar
	symLetrec
	symBegin
	symCond
	symAnd
	symOr
	symElse
	numSpecialSyms
)

var specialNames = [numSpecialSyms]string{
	"quote", "if", "define", "set!", "lambda", "let", "let*", "letrec",
	"begin", "cond", "and", "or", "else",
}

// New returns an interpreter whose global environment holds exactly the
// language's primitives.
func New() *Interp {
	in := &Interp{symIDs: make(map[string]int32)}
	for _, name := range specialNames {
		in.intern(name)
	}
	for i := range primTable {
		id := in.intern(primTable[i].name).n
		in.globals[id] = Value{t: tPrim, n: int64(i)}
	}
	return in
}

// intern returns the unique symbol Value with the given name.
func (in *Interp) intern(name string) Value {
	if id, ok := in.symIDs[name]; ok {
		return in.symVals[id]
	}
	id := int32(len(in.symVals))
	v := Value{t: tSym, n: int64(id), ref: name}
	in.symIDs[name] = id
	in.symVals = append(in.symVals, v)
	in.globals = append(in.globals, Value{t: tUnbound})
	return v
}

// Intern returns the symbol with the given name.
func (in *Interp) Intern(name string) Value { return in.intern(name) }

// Output returns the bytes written so far by display, newline and printed
// top-level results. The slice is valid until the next Run/Eval/ResetOutput.
func (in *Interp) Output() []byte { return in.out }

// ResetOutput discards the output buffer.
func (in *Interp) ResetOutput() { in.out = in.out[:0] }

// Run reads src as a sequence of forms and evaluates them in order in the
// global environment. The write form of every non-void result is appended to
// the output buffer followed by a newline. On a runtime error Run stops and
// returns a *Error; output produced before the error remains in the buffer.
func (in *Interp) Run(src []byte) error {
	_, err := in.exec(src, true)
	return err
}

// Eval evaluates src like Run but prints nothing for results; it returns the
// value of the last form (void for an empty program).
func (in *Interp) Eval(src string) (Value, error) {
	return in.exec([]byte(src), false)
}

func (in *Interp) exec(src []byte, print bool) (last Value, err error) {
	defer func() {
		if r := recover(); r != nil {
			in.stack = in.stack[:0]
			e, ok := r.(*Error)
			if !ok {
				panic(r)
			}
			err = e
		}
	}()
	last = voidV
	rd := &reader{in: in, src: src}
	for {
		form, ok := rd.next()
		if !ok {
			return last, nil
		}
		last = in.eval(in.compile(form), nil)
		if print && last.t != tVoid {
			in.out = appendValue(in.out, last, false)
			in.out = append(in.out, '\n')
		}
	}
}
