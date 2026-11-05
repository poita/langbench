package typeinfer

import (
	"example.com/typeinfer/syntax"
)

// Result is the outcome of one top-level declaration.
type Result struct {
	// Name is the bound name, or "" for a bare expression.
	Name string
	// Type is the principal type rendered as text, e.g. "('a -> 'b) -> 'a list
	// -> 'b list". It is empty if Err is not NoError.
	Type string
	// Err is NoError on success, otherwise why the declaration failed.
	Err ErrorKind
}

// OK reports whether the declaration type-checked.
func (r Result) OK() bool { return r.Err == NoError }

// String formats the result as one output line without the newline:
// "name : type", "- : type" or "error: kind".
func (r Result) String() string {
	b := r.Append(nil)
	return string(b[:len(b)-1])
}

// Append appends the String form followed by a newline to b.
func (r Result) Append(b []byte) []byte {
	if r.Err != NoError {
		b = append(b, "error: "...)
		b = append(b, r.Err.String()...)
	} else {
		if r.Name == "" {
			b = append(b, '-')
		} else {
			b = append(b, r.Name...)
		}
		b = append(b, " : "...)
		b = append(b, r.Type...)
	}
	return append(b, '\n')
}

// A Checker holds the top-level environment and infers declarations in it.
// Bindings made by successful declarations persist across calls to Check, so
// a program may be fed in several pieces. A Checker is not safe for
// concurrent use.
type Checker struct {
	names *syntax.Interner
	prog  *syntax.Program // program being checked

	nodes []node  // type node arena
	pool  []int32 // tuple component pool
	stamp uint64  // walk counter; never wraps in practice
	level int32   // current let-nesting level

	binds []binding
	top   []int32 // per interned name: index of its innermost binding, or -1

	nvars int32  // printer: variables named so far
	out   []byte // printer buffer
}

// NewChecker returns a Checker whose environment holds the built-in names
// (not, fst, snd, hd, tl, null, length, map, fold).
func NewChecker() *Checker {
	c := &Checker{names: syntax.NewInterner()}
	c.nodes = append(c.nodes, node{kind: kInt}, node{kind: kBool}, node{kind: kUnit})
	c.installBuiltins()
	return c
}

// Check parses src and infers each declaration in order, extending the
// environment with every successful let or let rec.
//
// If src is not syntactically valid, Check returns the results for the
// declarations that precede the error along with a *syntax.Error.
func (c *Checker) Check(src []byte) ([]Result, error) {
	prog, err := syntax.Parse(src, c.names)
	c.ensureNames(c.names.Len())
	c.prog = prog
	results := make([]Result, 0, len(prog.Decls))
	for _, d := range prog.Decls {
		results = append(results, c.checkDecl(d))
	}
	c.prog = nil
	return results, err
}

// TypeOf returns the rendered type scheme of a top-level (or built-in) name.
func (c *Checker) TypeOf(name string) (string, bool) {
	id, ok := c.names.Lookup(name)
	if !ok || int(id) >= len(c.top) || c.top[id] < 0 {
		return "", false
	}
	return c.render(c.binds[c.top[id]].typ), true
}

// Infer is a convenience wrapper that checks src with a fresh Checker.
func Infer(src string) ([]Result, error) {
	return NewChecker().Check([]byte(src))
}

// checkDecl infers one declaration. A failure leaves the environment as it
// was; a bare expression or failure also releases the type nodes it made.
func (c *Checker) checkDecl(d syntax.Decl) (res Result) {
	bindMark, nodeMark, poolMark := len(c.binds), len(c.nodes), len(c.pool)
	c.level = 0
	keep := false
	defer func() {
		if r := recover(); r != nil {
			te, ok := r.(typeError)
			if !ok {
				panic(r)
			}
			c.unwind(bindMark)
			c.level = 0
			res = Result{Err: te.kind}
			if d.Kind != syntax.DeclExpr {
				res.Name = c.names.Name(d.Name)
			}
		}
		if !keep {
			// Nothing from this declaration is reachable from the
			// environment, so its nodes can be reused.
			c.nodes, c.pool = c.nodes[:nodeMark], c.pool[:poolMark]
		}
	}()

	switch d.Kind {
	case syntax.DeclExpr:
		c.level = 1
		t := c.infer(d.Expr)
		c.level = 0
		return Result{Type: c.render(t)}
	case syntax.DeclLet:
		c.level = 1
		t := c.infer(d.Expr)
		c.level = 0
		poly := c.generalize(t)
		c.push(d.Name, t, poly)
		keep = true
		return Result{Name: c.names.Name(d.Name), Type: c.render(t)}
	default: // DeclLetRec
		t, poly := c.inferRec(d.Name, d.Expr)
		c.push(d.Name, t, poly)
		keep = true
		return Result{Name: c.names.Name(d.Name), Type: c.render(t)}
	}
}
