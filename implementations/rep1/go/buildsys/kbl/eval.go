// Package kbl implements the Kiln Build Language: a lexer, a parser, and a
// tree-walking interpreter that evaluates build files into a plan.Plan.
package kbl

import (
	"strconv"
	"strings"

	"buildsys/kerr"
	"buildsys/plan"
	"buildsys/vfs"
)

// MaxRuleDepth is the maximum nesting depth of rule instantiations.
const MaxRuleDepth = 64

// Evaluate lexes, parses and executes the build file at root (following
// include statements) against the workspace and returns the resulting plan.
// The returned error, if any, is a *kerr.Error.
func Evaluate(fs *vfs.FS, root string) (*plan.Plan, error) {
	it := &interp{fs: fs, plan: &plan.Plan{}, rules: map[string]*rule{}}
	src, ok := fs.Read(root)
	if !ok {
		return nil, kerr.New(kerr.IncludeMissing, "%s", root)
	}
	if err := it.runFile(root, src, newScope(nil)); err != nil {
		return nil, err
	}
	return it.plan, nil
}

type rule struct {
	params []param
	body   []stmt
	scope  *scope
}

type interp struct {
	fs     *vfs.FS
	plan   *plan.Plan
	rules  map[string]*rule
	stack  []string // include stack
	depth  int      // rule instantiation depth
	serial int
}

// runFile parses src in full, then executes it in sc.
func (it *interp) runFile(path, src string, sc *scope) error {
	stmts, err := parseFile(src)
	if err != nil {
		if se, ok := err.(*syntaxError); ok {
			return kerr.NewParse(path, se.line)
		}
		return err
	}
	it.stack = append(it.stack, path)
	defer func() { it.stack = it.stack[:len(it.stack)-1] }()
	return it.exec(stmts, sc)
}

func (it *interp) exec(stmts []stmt, sc *scope) error {
	for _, s := range stmts {
		if err := it.execStmt(s, sc); err != nil {
			return err
		}
	}
	return nil
}

func (it *interp) execStmt(s stmt, sc *scope) error {
	switch s := s.(type) {
	case *letStmt:
		v, err := it.eval(s.e, sc)
		if err != nil {
			return err
		}
		if _, dup := sc.vars[s.name]; dup {
			return kerr.New(kerr.Redefine, "%s", s.name)
		}
		sc.vars[s.name] = v
	case *setStmt:
		v, err := it.eval(s.e, sc)
		if err != nil {
			return err
		}
		if !sc.assign(s.name, v) {
			return kerr.New(kerr.SetUndefined, "%s", s.name)
		}
	case *includeStmt:
		return it.execInclude(s, sc)
	case *abortStmt:
		v, err := it.eval(s.e, sc)
		if err != nil {
			return err
		}
		if v.K != KStr {
			return kerr.NewType("abort message", "str", v.K.String())
		}
		return kerr.New(kerr.Abort, "%s", v.S)
	case *defaultStmt:
		v, err := it.eval(s.e, sc)
		if err != nil {
			return err
		}
		names, err := strList(v, "default")
		if err != nil {
			return err
		}
		it.plan.Defaults = append(it.plan.Defaults, names...)
	case *phonyStmt:
		return it.execPhony(s, sc)
	case *useStmt:
		return it.execUse(s, sc)
	case *whenStmt:
		for i, c := range s.conds {
			v, err := it.eval(c, sc)
			if err != nil {
				return err
			}
			if v.K != KBool {
				return kerr.NewType("when condition", "bool", v.K.String())
			}
			if v.I == 1 {
				return it.exec(s.bodies[i], newScope(sc))
			}
		}
		if s.hasOther {
			return it.exec(s.other, newScope(sc))
		}
	case *eachStmt:
		v, err := it.eval(s.subject, sc)
		if err != nil {
			return err
		}
		if v.K != KList {
			return kerr.NewType("each subject", "list", v.K.String())
		}
		for i, e := range v.L {
			child := newScope(sc)
			if s.index != "" {
				child.vars[s.index] = vInt(int64(i))
			}
			child.vars[s.name] = e
			if err := it.exec(s.body, child); err != nil {
				return err
			}
		}
	case *ruleStmt:
		if _, dup := it.rules[s.name]; dup {
			return kerr.New(kerr.Redefine, "%s", s.name)
		}
		it.rules[s.name] = &rule{params: s.params, body: s.body, scope: sc}
	case *stepStmt:
		return it.execStep(s, sc)
	default:
		panic("kbl: unknown statement")
	}
	return nil
}

func (it *interp) execInclude(s *includeStmt, sc *scope) error {
	v, err := it.eval(s.e, sc)
	if err != nil {
		return err
	}
	if v.K != KStr {
		return kerr.NewType("include path", "str", v.K.String())
	}
	if !vfs.ValidPath(v.S) {
		return kerr.New(kerr.BadPath, "%s", v.S)
	}
	src, ok := it.fs.Read(v.S)
	if !ok {
		return kerr.New(kerr.IncludeMissing, "%s", v.S)
	}
	for _, f := range it.stack {
		if f == v.S {
			return kerr.New(kerr.IncludeCycle, "%s", v.S)
		}
	}
	return it.runFile(v.S, src, sc)
}

func (it *interp) execPhony(s *phonyStmt, sc *scope) error {
	v, err := it.eval(s.e, sc)
	if err != nil {
		return err
	}
	deps, err := strList(v, "phony "+s.name)
	if err != nil {
		return err
	}
	for _, d := range deps {
		if err := checkRef(d); err != nil {
			return err
		}
	}
	if !it.plan.AddPhony(&plan.Phony{Name: s.name, Deps: deps}) {
		return kerr.New(kerr.DupPhony, "%s", s.name)
	}
	return nil
}

func (it *interp) execUse(s *useStmt, sc *scope) error {
	r, ok := it.rules[s.rule]
	if !ok {
		return kerr.New(kerr.UnknownRule, "%s", s.rule)
	}
	if it.depth+1 > MaxRuleDepth {
		return kerr.New(kerr.RuleRecursion, "%s", s.rule)
	}
	type kwArg struct {
		name string
		v    Value
	}
	var pos []Value
	var kws []kwArg
	for _, a := range s.args {
		v, err := it.eval(a.e, sc)
		if err != nil {
			return err
		}
		if a.kw == "" {
			pos = append(pos, v)
		} else {
			kws = append(kws, kwArg{a.kw, v})
		}
	}
	ns := newScope(r.scope)
	if len(pos) > len(r.params) {
		return kerr.New(kerr.Arity, "rule %s: expected %d, got %d", s.rule, len(r.params), len(pos))
	}
	for i, v := range pos {
		ns.vars[r.params[i].name] = v
	}
	for _, kw := range kws {
		known := false
		for _, p := range r.params {
			if p.name == kw.name {
				known = true
				break
			}
		}
		if !known {
			return kerr.New(kerr.Arg, "rule %s: unknown argument %s", s.rule, kw.name)
		}
		if _, bound := ns.vars[kw.name]; bound {
			return kerr.New(kerr.Arg, "rule %s: duplicate argument %s", s.rule, kw.name)
		}
		ns.vars[kw.name] = kw.v
	}
	for _, p := range r.params {
		if _, bound := ns.vars[p.name]; bound {
			continue
		}
		if p.def == nil {
			return kerr.New(kerr.Arg, "rule %s: missing argument %s", s.rule, p.name)
		}
		v, err := it.eval(p.def, ns)
		if err != nil {
			return err
		}
		ns.vars[p.name] = v
	}
	it.depth++
	defer func() { it.depth-- }()
	return it.exec(r.body, ns)
}

// strList converts v, which must be a str or a list of str, to a []string. site
// is the E_TYPE site used on failure.
func strList(v Value, site string) ([]string, error) {
	switch v.K {
	case KStr:
		return []string{v.S}, nil
	case KList:
		out := make([]string, len(v.L))
		for i, e := range v.L {
			if e.K != KStr {
				return nil, kerr.NewType(site, "strlist", e.K.String())
			}
			out[i] = e.S
		}
		return out, nil
	}
	return nil, kerr.NewType(site, "strlist", v.K.String())
}

// checkRef validates the shape of an in/after/phony reference: "@" followed by
// an identifier-shaped name, or a workspace path.
func checkRef(s string) error {
	if strings.HasPrefix(s, "@") {
		name := s[1:]
		if name != "" && isIdentStart(name[0]) {
			ok := true
			for i := 1; i < len(name); i++ {
				if !isIdentStart(name[i]) && !isDigit(name[i]) {
					ok = false
					break
				}
			}
			if ok {
				return nil
			}
		}
		return kerr.New(kerr.BadPath, "%s", s)
	}
	if !vfs.ValidPath(s) {
		return kerr.New(kerr.BadPath, "%s", s)
	}
	return nil
}

// ---- expressions ----

func (it *interp) eval(e expr, sc *scope) (Value, error) {
	switch e := e.(type) {
	case *intLit:
		return vInt(e.v), nil
	case *boolLit:
		return vBool(e.v), nil
	case *strLit:
		return it.evalString(e, sc)
	case *varRef:
		v, ok := sc.lookup(e.name)
		if !ok {
			return Value{}, kerr.New(kerr.UnknownVar, "%s", e.name)
		}
		return v, nil
	case *list:
		elems := make([]Value, len(e.elems))
		for i, x := range e.elems {
			v, err := it.eval(x, sc)
			if err != nil {
				return Value{}, err
			}
			elems[i] = v
		}
		return vList(elems), nil
	case *unary:
		return it.evalUnary(e, sc)
	case *binary:
		return it.evalBinary(e, sc)
	case *call:
		return it.evalCall(e, sc)
	case *index:
		return it.evalIndex(e, sc)
	}
	panic("kbl: unknown expression")
}

func (it *interp) evalString(s *strLit, sc *scope) (Value, error) {
	if len(s.parts) == 1 && s.parts[0].e == nil {
		return vStr(s.parts[0].lit), nil
	}
	var b strings.Builder
	for _, p := range s.parts {
		if p.e == nil {
			b.WriteString(p.lit)
			continue
		}
		v, err := it.eval(p.e, sc)
		if err != nil {
			return Value{}, err
		}
		if err := writeInterp(&b, v); err != nil {
			return Value{}, err
		}
	}
	return vStr(b.String()), nil
}

// writeInterp renders a scalar as interpolation does.
func writeInterp(b *strings.Builder, v Value) error {
	switch v.K {
	case KStr:
		b.WriteString(v.S)
	case KInt:
		b.WriteString(strconv.FormatInt(v.I, 10))
	case KBool:
		if v.I == 1 {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	default:
		return kerr.New(kerr.Interp, "list")
	}
	return nil
}

func (it *interp) evalUnary(e *unary, sc *scope) (Value, error) {
	v, err := it.eval(e.x, sc)
	if err != nil {
		return Value{}, err
	}
	if e.op == "!" {
		if v.K != KBool {
			return Value{}, kerr.NewType("operator !", "bool", v.K.String())
		}
		return vBool(v.I == 0), nil
	}
	if v.K != KInt {
		return Value{}, kerr.NewType("operator -", "int", v.K.String())
	}
	return vInt(-v.I), nil
}

func (it *interp) evalBinary(e *binary, sc *scope) (Value, error) {
	l, err := it.eval(e.l, sc)
	if err != nil {
		return Value{}, err
	}
	if e.op == "||" || e.op == "&&" {
		if l.K != KBool {
			return Value{}, kerr.NewType("operator "+e.op, "bool", l.K.String())
		}
		if (e.op == "||") == (l.I == 1) {
			return l, nil // short circuit
		}
		r, err := it.eval(e.r, sc)
		if err != nil {
			return Value{}, err
		}
		if r.K != KBool {
			return Value{}, kerr.NewType("operator "+e.op, "bool", r.K.String())
		}
		return r, nil
	}
	r, err := it.eval(e.r, sc)
	if err != nil {
		return Value{}, err
	}
	switch e.op {
	case "==":
		return vBool(equal(l, r)), nil
	case "!=":
		return vBool(!equal(l, r)), nil
	case "<":
		return vBool(compare(l, r) < 0), nil
	case "<=":
		return vBool(compare(l, r) <= 0), nil
	case ">":
		return vBool(compare(l, r) > 0), nil
	case ">=":
		return vBool(compare(l, r) >= 0), nil
	}
	want := KInt
	switch e.op {
	case "++":
		want = KList
	case "~":
		want = KStr
	}
	site := "operator " + e.op
	if l.K != want {
		return Value{}, kerr.NewType(site, want.String(), l.K.String())
	}
	if r.K != want {
		return Value{}, kerr.NewType(site, want.String(), r.K.String())
	}
	switch e.op {
	case "++":
		out := make([]Value, 0, len(l.L)+len(r.L))
		out = append(append(out, l.L...), r.L...)
		return vList(out), nil
	case "~":
		return vStr(l.S + r.S), nil
	case "+":
		return vInt(l.I + r.I), nil
	case "-":
		return vInt(l.I - r.I), nil
	case "*":
		return vInt(l.I * r.I), nil
	}
	if r.I == 0 {
		return Value{}, kerr.New(kerr.DivZero, "")
	}
	if e.op == "/" {
		return vInt(l.I / r.I), nil
	}
	return vInt(l.I % r.I), nil
}

func (it *interp) evalIndex(e *index, sc *scope) (Value, error) {
	x, err := it.eval(e.x, sc)
	if err != nil {
		return Value{}, err
	}
	i, err := it.eval(e.i, sc)
	if err != nil {
		return Value{}, err
	}
	if i.K != KInt {
		return Value{}, kerr.NewType("index", "int", i.K.String())
	}
	if x.K != KStr && x.K != KList {
		return Value{}, kerr.NewType("index target", "str|list", x.K.String())
	}
	n := int64(len(x.L))
	if x.K == KStr {
		n = int64(len(x.S))
	}
	idx := i.I
	if idx < 0 {
		idx += n
	}
	if idx < 0 || idx >= n {
		return Value{}, kerr.New(kerr.Arg, "fn index: out of range")
	}
	if x.K == KStr {
		return vStr(x.S[idx : idx+1]), nil
	}
	return x.L[idx], nil
}

func (it *interp) evalCall(e *call, sc *scope) (Value, error) {
	fn, ok := builtins[e.name]
	if !ok {
		return Value{}, kerr.New(kerr.UnknownFunc, "%s", e.name)
	}
	args := make([]Value, len(e.args))
	for i, a := range e.args {
		v, err := it.eval(a, sc)
		if err != nil {
			return Value{}, err
		}
		args[i] = v
	}
	if n := len(args); n < fn.min || n > fn.max {
		if fn.min == fn.max {
			return Value{}, kerr.New(kerr.Arity, "fn %s: expected %d, got %d", e.name, fn.min, n)
		}
		return Value{}, kerr.New(kerr.Arity, "fn %s: expected %d-%d, got %d", e.name, fn.min, fn.max, n)
	}
	for i, a := range args {
		t := fn.types[min(i, len(fn.types)-1)]
		if !t.accepts(a) {
			return Value{}, kerr.NewType("fn "+e.name+" argument "+strconv.Itoa(i+1), t.expected(), a.K.String())
		}
	}
	return fn.run(it, args)
}
