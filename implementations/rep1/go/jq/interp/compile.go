// Package interp compiles filter syntax trees into closures and runs them.
//
// Evaluation is lazy and push-based: every compiled node is a function that
// receives an input value and a callback, and calls the callback once per
// output in jq's order. An error returned by the callback aborts evaluation
// and is passed back to the caller unchanged, which gives short-circuiting
// and early termination without goroutines.
package interp

import (
	"fmt"

	"example.com/jq/syntax"
	"example.com/jq/value"
)

// env is a persistent (linked) variable environment.
type env struct {
	val    Value
	parent *env
}

type evalFn func(e *env, in Value, out func(Value) error) error

// Program is a compiled filter. It is immutable and safe for concurrent use.
type Program struct {
	run evalFn
}

// Compile turns a syntax tree into a Program. It reports unknown builtins,
// wrong argument counts and undefined variables.
func Compile(n syntax.Node) (p *Program, err error) {
	defer func() {
		if r := recover(); r != nil {
			if ce, ok := r.(compileError); ok {
				p, err = nil, ce
				return
			}
			panic(r)
		}
	}()
	c := &compiler{}
	return &Program{run: c.compile(n)}, nil
}

// Run evaluates the program on input, calling yield for every output in
// order. It returns nil when evaluation completes, an *Error if a jq runtime
// error was raised, or whatever error yield returned (which stops evaluation).
func (p *Program) Run(input Value, yield func(Value) error) error {
	return p.run(nil, input, yield)
}

type compileError string

func (e compileError) Error() string { return string(e) }

type compiler struct {
	scope []string // variable names, innermost last
}

func (c *compiler) fail(format string, a ...any) {
	panic(compileError(fmt.Sprintf("jq: compile error: "+format, a...)))
}

func (c *compiler) push(name string) { c.scope = append(c.scope, name) }
func (c *compiler) pop()             { c.scope = c.scope[:len(c.scope)-1] }

func (c *compiler) compile(n syntax.Node) evalFn {
	switch n := n.(type) {
	case *syntax.Identity:
		return func(_ *env, in Value, out func(Value) error) error { return out(in) }
	case *syntax.Literal:
		v := n.Value
		return func(_ *env, _ Value, out func(Value) error) error { return out(v) }
	case *syntax.Var:
		return c.compileVar(n)
	case *syntax.Index:
		return c.compileIndex(n)
	case *syntax.Iterate:
		return c.compileIterate(n)
	case *syntax.Slice:
		return c.compileSlice(n)
	case *syntax.Try:
		return compileTry(c.compile(n.Body))
	case *syntax.Pipe:
		l, r := c.compile(n.L), c.compile(n.R)
		return func(e *env, in Value, out func(Value) error) error {
			return l(e, in, func(v Value) error { return r(e, v, out) })
		}
	case *syntax.Comma:
		l, r := c.compile(n.L), c.compile(n.R)
		return func(e *env, in Value, out func(Value) error) error {
			if err := l(e, in, out); err != nil {
				return err
			}
			return r(e, in, out)
		}
	case *syntax.Binary:
		return c.compileBinary(n)
	case *syntax.And:
		l, r := c.compile(n.L), c.compile(n.R)
		return func(e *env, in Value, out func(Value) error) error {
			return l(e, in, func(a Value) error {
				if !value.Truthy(a) {
					return out(false)
				}
				return r(e, in, func(b Value) error { return out(value.Truthy(b)) })
			})
		}
	case *syntax.Or:
		l, r := c.compile(n.L), c.compile(n.R)
		return func(e *env, in Value, out func(Value) error) error {
			return l(e, in, func(a Value) error {
				if value.Truthy(a) {
					return out(true)
				}
				return r(e, in, func(b Value) error { return out(value.Truthy(b)) })
			})
		}
	case *syntax.Neg:
		x := c.compile(n.X)
		return func(e *env, in Value, out func(Value) error) error {
			return x(e, in, func(v Value) error {
				f, ok := v.(float64)
				if !ok {
					return errf("%s cannot be negated", describe(v))
				}
				return out(-f)
			})
		}
	case *syntax.Array:
		return c.compileArray(n)
	case *syntax.Object:
		return c.compileObject(n)
	case *syntax.If:
		return c.compileIf(n)
	case *syntax.As:
		src := c.compile(n.Src)
		c.push(n.Name)
		body := c.compile(n.Body)
		c.pop()
		return func(e *env, in Value, out func(Value) error) error {
			return src(e, in, func(v Value) error { return body(&env{v, e}, in, out) })
		}
	case *syntax.Reduce:
		return c.compileReduce(n)
	case *syntax.Call:
		return c.compileCall(n)
	}
	c.fail("unsupported syntax node %T", n)
	return nil
}

func (c *compiler) compileVar(n *syntax.Var) evalFn {
	for i := len(c.scope) - 1; i >= 0; i-- {
		if c.scope[i] == n.Name {
			depth := len(c.scope) - 1 - i
			return func(e *env, _ Value, out func(Value) error) error {
				for d := depth; d > 0; d-- {
					e = e.parent
				}
				return out(e.val)
			}
		}
	}
	c.fail("$%s is not defined", n.Name)
	return nil
}

func compileTry(body evalFn) evalFn {
	return func(e *env, in Value, out func(Value) error) error {
		err := body(e, in, func(v Value) error {
			if err := out(v); err != nil {
				return &passThrough{err}
			}
			return nil
		})
		switch x := err.(type) {
		case nil:
			return nil
		case *passThrough:
			return x.err
		}
		return nil // an error raised inside the term: swallowed, stream ends
	}
}

func isConst(n syntax.Node) (Value, bool) {
	if l, ok := n.(*syntax.Literal); ok {
		return l.Value, true
	}
	return nil, false
}

func (c *compiler) compileIndex(n *syntax.Index) evalFn {
	term := c.compile(n.Term)
	opt := n.Opt
	_, identity := n.Term.(*syntax.Identity)
	if k, ok := isConst(n.Key); ok {
		if identity {
			return func(_ *env, in Value, out func(Value) error) error {
				v, err := index(in, k)
				if err != nil {
					if opt {
						return nil
					}
					return err
				}
				return out(v)
			}
		}
		return func(e *env, in Value, out func(Value) error) error {
			return term(e, in, func(t Value) error {
				v, err := index(t, k)
				if err != nil {
					if opt {
						return nil
					}
					return err
				}
				return out(v)
			})
		}
	}
	key := c.compile(n.Key)
	return func(e *env, in Value, out func(Value) error) error {
		return key(e, in, func(k Value) error {
			return term(e, in, func(t Value) error {
				v, err := index(t, k)
				if err != nil {
					if opt {
						return nil
					}
					return err
				}
				return out(v)
			})
		})
	}
}

func (c *compiler) compileIterate(n *syntax.Iterate) evalFn {
	term := c.compile(n.Term)
	opt := n.Opt
	return func(e *env, in Value, out func(Value) error) error {
		return term(e, in, func(t Value) error {
			switch t.(type) {
			case []Value, *value.Object:
				return iterate(t, out)
			}
			if opt {
				return nil
			}
			return errf("Cannot iterate over %s", describe(t))
		})
	}
}

func (c *compiler) compileSlice(n *syntax.Slice) evalFn {
	term := c.compile(n.Term)
	opt := n.Opt
	absent := func(_ *env, _ Value, out func(Value) error) error { return out(nil) }
	from, to := evalFn(absent), evalFn(absent)
	if n.From != nil {
		from = c.compile(n.From)
	}
	if n.To != nil {
		to = c.compile(n.To)
	}
	return func(e *env, in Value, out func(Value) error) error {
		return from(e, in, func(a Value) error {
			return to(e, in, func(b Value) error {
				return term(e, in, func(t Value) error {
					v, err := slice(t, a, b)
					if err != nil {
						if opt {
							return nil
						}
						return err
					}
					return out(v)
				})
			})
		})
	}
}

func (c *compiler) compileBinary(n *syntax.Binary) evalFn {
	l, r := c.compile(n.L), c.compile(n.R)
	op := n.Op
	if k, ok := isConst(n.R); ok {
		return func(e *env, in Value, out func(Value) error) error {
			return l(e, in, func(a Value) error {
				v, err := binary(op, a, k)
				if err != nil {
					return err
				}
				return out(v)
			})
		}
	}
	return func(e *env, in Value, out func(Value) error) error {
		return r(e, in, func(b Value) error {
			return l(e, in, func(a Value) error {
				v, err := binary(op, a, b)
				if err != nil {
					return err
				}
				return out(v)
			})
		})
	}
}

func (c *compiler) compileArray(n *syntax.Array) evalFn {
	if n.Body == nil {
		return func(_ *env, _ Value, out func(Value) error) error { return out([]Value{}) }
	}
	body := c.compile(n.Body)
	return func(e *env, in Value, out func(Value) error) error {
		arr := []Value{}
		if err := body(e, in, func(v Value) error {
			arr = append(arr, v)
			return nil
		}); err != nil {
			return err
		}
		return out(arr)
	}
}

func (c *compiler) compileObject(n *syntax.Object) evalFn {
	type entry struct {
		key, val evalFn
		constKey string
		isConst  bool
	}
	entries := make([]entry, len(n.Entries))
	for i, en := range n.Entries {
		if k, ok := isConst(en.Key); ok {
			entries[i].constKey, entries[i].isConst = k.(string), true
		} else {
			entries[i].key = c.compile(en.Key)
		}
		entries[i].val = c.compile(en.Val)
	}
	return func(e *env, in Value, out func(Value) error) error {
		keys := make([]string, len(entries))
		vals := make([]Value, len(entries))
		var step func(i int) error
		step = func(i int) error {
			if i == len(entries) {
				b := value.NewBuilder(len(entries))
				for j, k := range keys {
					b.Set(k, vals[j])
				}
				return out(b.Build())
			}
			en := &entries[i]
			withKey := func(k string) error {
				keys[i] = k
				return en.val(e, in, func(v Value) error {
					vals[i] = v
					return step(i + 1)
				})
			}
			if en.isConst {
				return withKey(en.constKey)
			}
			return en.key(e, in, func(k Value) error {
				ks, ok := k.(string)
				if !ok {
					return errf("Object keys must be strings")
				}
				return withKey(ks)
			})
		}
		return step(0)
	}
}

func (c *compiler) compileIf(n *syntax.If) evalFn {
	cond, then := c.compile(n.Cond), c.compile(n.Then)
	els := evalFn(func(_ *env, in Value, out func(Value) error) error { return out(in) })
	if n.Else != nil {
		els = c.compile(n.Else)
	}
	return func(e *env, in Value, out func(Value) error) error {
		return cond(e, in, func(v Value) error {
			if value.Truthy(v) {
				return then(e, in, out)
			}
			return els(e, in, out)
		})
	}
}

func (c *compiler) compileReduce(n *syntax.Reduce) evalFn {
	src, init := c.compile(n.Src), c.compile(n.Init)
	c.push(n.Name)
	update := c.compile(n.Update)
	c.pop()
	return func(e *env, in Value, out func(Value) error) error {
		return init(e, in, func(acc Value) error {
			err := src(e, in, func(v Value) error {
				var last Value
				err := update(&env{v, e}, acc, func(x Value) error {
					last = x
					return nil
				})
				acc = last
				return err
			})
			if err != nil {
				return err
			}
			return out(acc)
		})
	}
}
