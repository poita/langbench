// Package kbl implements the Kiln Build Language: lexer, parser, values,
// expression evaluator, the 39 built-in functions and the statement
// interpreter that turns build files into a Program of steps.
package kbl

import (
	"strings"

	"kiln/cmds"
	"kiln/errs"
	"kiln/vfs"
)

const maxRuleDepth = 64

// Scope is a mutable name-to-value mapping with a parent link.
type Scope struct {
	vars   map[string]Value
	parent *Scope
}

func newScope(parent *Scope) *Scope { return &Scope{parent: parent} }

func (s *Scope) lookup(name string) (Value, bool) {
	for ; s != nil; s = s.parent {
		if v, ok := s.vars[name]; ok {
			return v, true
		}
	}
	return Value{}, false
}

func (s *Scope) bound(name string) bool {
	_, ok := s.vars[name]
	return ok
}

func (s *Scope) define(name string, v Value) {
	if s.vars == nil {
		s.vars = make(map[string]Value, 4)
	}
	s.vars[name] = v
}

// assign replaces name in the innermost scope that binds it.
func (s *Scope) assign(name string, v Value) bool {
	for ; s != nil; s = s.parent {
		if _, ok := s.vars[name]; ok {
			s.vars[name] = v
			return true
		}
	}
	return false
}

type rule struct {
	name   string
	params []param
	body   []Stmt
	scope  *Scope
}

// Interp evaluates build files against a file system.
type Interp struct {
	fs       *vfs.FS
	prog     *Program
	phonyIdx map[string]bool
	rules    map[string]*rule
	includes []string
	depth    int
}

// Evaluate lexes, parses and executes main.kiln (following includes) in a
// fresh root scope and returns the steps, phony targets and default list it
// declares. It returns E_NO_BUILD_FILE if main.kiln does not exist.
func Evaluate(fs *vfs.FS) (*Program, *errs.Error) {
	if !fs.Exists(MainFile) {
		return nil, errs.New(errs.NoBuildFile, MainFile)
	}
	it := &Interp{
		fs:       fs,
		prog:     &Program{},
		phonyIdx: map[string]bool{},
		rules:    map[string]*rule{},
	}
	if err := it.runFile(MainFile, newScope(nil)); err != nil {
		return nil, err
	}
	return it.prog, nil
}

func (it *Interp) runFile(path string, sc *Scope) *errs.Error {
	data, _ := it.fs.Read(path)
	f, err := Parse(path, string(data))
	if err != nil {
		return err
	}
	it.includes = append(it.includes, path)
	err = it.execBlock(f.Stmts, sc)
	it.includes = it.includes[:len(it.includes)-1]
	return err
}

func (it *Interp) execBlock(stmts []Stmt, sc *Scope) *errs.Error {
	for _, st := range stmts {
		if err := it.exec(st, sc); err != nil {
			return err
		}
	}
	return nil
}

func (it *Interp) exec(st Stmt, sc *Scope) *errs.Error {
	switch s := st.(type) {
	case *letStmt:
		v, err := it.eval(s.x, sc)
		if err != nil {
			return err
		}
		if sc.bound(s.name) {
			return errs.New(errs.Redefine, "%s", s.name)
		}
		sc.define(s.name, v)
	case *setStmt:
		v, err := it.eval(s.x, sc)
		if err != nil {
			return err
		}
		if !sc.assign(s.name, v) {
			return errs.New(errs.SetUndefined, "%s", s.name)
		}
	case *includeStmt:
		return it.execInclude(s, sc)
	case *abortStmt:
		v, err := it.eval(s.x, sc)
		if err != nil {
			return err
		}
		if v.K != KStr {
			return typeErr("abort message", mS, v.K)
		}
		return errs.New(errs.Abort, "%s", v.S)
	case *defaultStmt:
		v, err := it.eval(s.x, sc)
		if err != nil {
			return err
		}
		l, err := strList(v, "default")
		if err != nil {
			return err
		}
		it.prog.Defaults = append(it.prog.Defaults, l...)
	case *phonyStmt:
		return it.execPhony(s, sc)
	case *whenStmt:
		for i, c := range s.conds {
			v, err := it.eval(c, sc)
			if err != nil {
				return err
			}
			if v.K != KBool {
				return typeErr("when condition", mB, v.K)
			}
			if v.I != 0 {
				return it.execBlock(s.bodies[i], newScope(sc))
			}
		}
		if s.otherwise != nil {
			return it.execBlock(s.otherwise, newScope(sc))
		}
	case *eachStmt:
		v, err := it.eval(s.x, sc)
		if err != nil {
			return err
		}
		if v.K != KList {
			return typeErr("each subject", mL, v.K)
		}
		for i, e := range v.L {
			inner := newScope(sc)
			if s.index != "" {
				inner.define(s.index, intVal(int64(i)))
			}
			inner.define(s.name, e)
			if err := it.execBlock(s.body, inner); err != nil {
				return err
			}
		}
	case *ruleStmt:
		if _, dup := it.rules[s.name]; dup {
			return errs.New(errs.Redefine, "%s", s.name)
		}
		it.rules[s.name] = &rule{name: s.name, params: s.params, body: s.body, scope: sc}
	case *useStmt:
		return it.execUse(s, sc)
	case *stepStmt:
		return it.execStep(s, sc)
	}
	return nil
}

func (it *Interp) execInclude(s *includeStmt, sc *Scope) *errs.Error {
	v, err := it.eval(s.x, sc)
	if err != nil {
		return err
	}
	if v.K != KStr {
		return typeErr("include path", mS, v.K)
	}
	if !vfs.ValidPath(v.S) {
		return errs.New(errs.BadPath, "%s", v.S)
	}
	if !it.fs.Exists(v.S) {
		return errs.New(errs.IncludeMissing, "%s", v.S)
	}
	for _, p := range it.includes {
		if p == v.S {
			return errs.New(errs.IncludeCycle, "%s", v.S)
		}
	}
	return it.runFile(v.S, sc)
}

// strList converts a str or list-of-str value; site names the construct for
// type errors.
func strList(v Value, site string) ([]string, *errs.Error) {
	switch v.K {
	case KStr:
		return []string{v.S}, nil
	case KList:
		out := make([]string, len(v.L))
		for i, e := range v.L {
			if e.K != KStr {
				return nil, errs.New(errs.Type, "%s: expected strlist, got %s", site, e.K)
			}
			out[i] = e.S
		}
		return out, nil
	}
	return nil, errs.New(errs.Type, "%s: expected strlist, got %s", site, v.K)
}

func (it *Interp) execPhony(s *phonyStmt, sc *Scope) *errs.Error {
	v, err := it.eval(s.x, sc)
	if err != nil {
		return err
	}
	deps, err := strList(v, "phony "+s.name)
	if err != nil {
		return err
	}
	for _, d := range deps {
		if !CheckRef(d) {
			return errs.New(errs.BadPath, "%s", d)
		}
	}
	if it.phonyIdx[s.name] {
		return errs.New(errs.DupPhony, "%s", s.name)
	}
	it.phonyIdx[s.name] = true
	it.prog.Phonies = append(it.prog.Phonies, &Phony{Name: s.name, Deps: deps})
	return nil
}

func (it *Interp) execUse(s *useStmt, sc *Scope) *errs.Error {
	r, ok := it.rules[s.name]
	if !ok {
		return errs.New(errs.UnknownRule, "%s", s.name)
	}
	if it.depth+1 > maxRuleDepth {
		return errs.New(errs.RuleRecursion, "%s", s.name)
	}
	pos := make([]Value, len(s.pos))
	for i, x := range s.pos {
		v, err := it.eval(x, sc)
		if err != nil {
			return err
		}
		pos[i] = v
	}
	kws := make([]Value, len(s.kws))
	for i, k := range s.kws {
		v, err := it.eval(k.x, sc)
		if err != nil {
			return err
		}
		kws[i] = v
	}
	inner := newScope(r.scope)
	if len(pos) > len(r.params) {
		return errs.New(errs.Arity, "rule %s: expected %d, got %d", r.name, len(r.params), len(pos))
	}
	for i, v := range pos {
		inner.define(r.params[i].name, v)
	}
	for i, k := range s.kws {
		idx := -1
		for j := range r.params {
			if r.params[j].name == k.name {
				idx = j
				break
			}
		}
		if idx < 0 {
			return argErr("rule", r.name, "unknown argument "+k.name)
		}
		if inner.bound(k.name) {
			return argErr("rule", r.name, "duplicate argument "+k.name)
		}
		inner.define(k.name, kws[i])
	}
	for _, p := range r.params {
		if inner.bound(p.name) {
			continue
		}
		if p.def == nil {
			return argErr("rule", r.name, "missing argument "+p.name)
		}
		v, err := it.eval(p.def, inner)
		if err != nil {
			return err
		}
		inner.define(p.name, v)
	}
	it.depth++
	err := it.execBlock(r.body, inner)
	it.depth--
	return err
}

func (it *Interp) execStep(s *stepStmt, sc *Scope) *errs.Error {
	st := &Step{}
	var (
		haveCost, haveDepfile, haveCmd bool
		cmdName                        string
		cmdArgs                        []cmds.Arg
		spec                           *cmds.Spec
	)
	for _, f := range s.fields {
		switch f.kind {
		case fOut, fIn, fAfter:
			name := [...]string{fOut: "out", fIn: "in", fAfter: "after"}[f.kind]
			v, err := it.eval(f.x, sc)
			if err != nil {
				return err
			}
			l, err := strList(v, "field "+name)
			if err != nil {
				return err
			}
			switch f.kind {
			case fOut:
				st.Outs = append(st.Outs, l...)
			case fIn:
				st.Ins = append(st.Ins, l...)
			default:
				st.After = append(st.After, l...)
			}
		case fCost:
			if haveCost {
				return errs.New(errs.StepField, "duplicate cost")
			}
			haveCost = true
			v, err := it.eval(f.x, sc)
			if err != nil {
				return err
			}
			if v.K != KInt {
				return typeErr("field cost", mI, v.K)
			}
			if v.I < 0 {
				return argErr("field", "cost", "negative")
			}
			st.Cost = v.I
		case fDepfile:
			if haveDepfile {
				return errs.New(errs.StepField, "duplicate depfile")
			}
			haveDepfile = true
			v, err := it.eval(f.x, sc)
			if err != nil {
				return err
			}
			if v.K != KStr {
				return typeErr("field depfile", mS, v.K)
			}
			st.Depfile = v.S
		case fCmd:
			if haveCmd {
				return errs.New(errs.StepField, "duplicate cmd")
			}
			haveCmd = true
			sp, ok := cmds.Lookup(f.cmdName)
			if !ok {
				return errs.New(errs.UnknownCmd, "%s", f.cmdName)
			}
			vals := make([]Value, len(f.args))
			for i, x := range f.args {
				v, err := it.eval(x, sc)
				if err != nil {
					return err
				}
				vals[i] = v
			}
			if len(vals) != len(sp.Params) {
				return errs.New(errs.Arity, "cmd %s: expected %d, got %d", sp.Name, len(sp.Params), len(vals))
			}
			args := make([]cmds.Arg, len(vals))
			for i, v := range vals {
				if sp.Params[i] == cmds.Int {
					if v.K != KInt {
						return typeErr("cmd "+sp.Name+" argument "+itoa(i+1), mI, v.K)
					}
					args[i] = cmds.IntArg(v.I)
				} else {
					if v.K != KStr {
						return typeErr("cmd "+sp.Name+" argument "+itoa(i+1), mS, v.K)
					}
					args[i] = cmds.StrArg(v.S)
				}
			}
			cmdName, cmdArgs, spec = sp.Name, args, sp
		}
	}
	// Validation at the closing brace.
	if !haveCmd {
		return errs.New(errs.StepField, "missing cmd")
	}
	if len(st.Outs) == 0 {
		return errs.New(errs.StepField, "missing out")
	}
	check := func(p string) *errs.Error {
		if !vfs.ValidPath(p) {
			return errs.New(errs.BadPath, "%s", p)
		}
		if !vfs.IsGenerated(p) {
			return errs.New(errs.OutputPath, "%s", p)
		}
		return nil
	}
	for _, p := range st.Outs {
		if err := check(p); err != nil {
			return err
		}
	}
	if haveDepfile {
		if err := check(st.Depfile); err != nil {
			return err
		}
	}
	for _, list := range [][]string{st.Ins, st.After} {
		for _, r := range list {
			if !CheckRef(r) {
				return errs.New(errs.BadPath, "%s", r)
			}
		}
	}
	for _, r := range st.Ins {
		if r[0] != '@' {
			st.FileIns = append(st.FileIns, r)
		}
	}
	if n := len(st.FileIns); n < spec.MinIn || (spec.MaxIn != cmds.Unbounded && n > spec.MaxIn) {
		return errs.New(errs.CmdShape, "%s: expected inputs %s, got %d", cmdName, spec.InputRange(), n)
	}
	if len(st.Outs) != 1 {
		return errs.New(errs.CmdShape, "%s: expected outputs 1, got %d", cmdName, len(st.Outs))
	}
	if spec.Depfile && !haveDepfile {
		return errs.New(errs.CmdShape, "%s: depfile required", cmdName)
	}
	if !spec.Depfile && haveDepfile {
		return errs.New(errs.CmdShape, "%s: depfile not allowed", cmdName)
	}
	if err := spec.CheckArgs(cmdArgs); err != nil {
		return err
	}
	st.Spec = spec
	st.Args = cmdArgs
	st.CmdStr = cmds.Render(cmdName, cmdArgs)
	if !haveCost {
		st.Cost = spec.DefaultCost
	}
	st.Serial = len(it.prog.Steps)
	it.prog.Steps = append(it.prog.Steps, st)
	return nil
}

func itoa(i int) string { return intVal(int64(i)).text() }

// ---- expressions ----

func (it *Interp) eval(e Expr, sc *Scope) (Value, *errs.Error) {
	switch x := e.(type) {
	case *intLit:
		return intVal(x.v), nil
	case *boolLit:
		return boolVal(x.v), nil
	case *varRef:
		v, ok := sc.lookup(x.name)
		if !ok {
			return Value{}, errs.New(errs.UnknownVar, "%s", x.name)
		}
		return v, nil
	case *strLit:
		return it.evalStr(x, sc)
	case *listLit:
		out := make([]Value, len(x.elems))
		for i, el := range x.elems {
			v, err := it.eval(el, sc)
			if err != nil {
				return Value{}, err
			}
			out[i] = v
		}
		return listVal(out), nil
	case *unary:
		return it.evalUnary(x, sc)
	case *binary:
		return it.evalBinary(x, sc)
	case *index:
		return it.evalIndex(x, sc)
	case *call:
		return it.evalCall(x, sc)
	}
	panic("kbl: unknown expression node")
}

func (it *Interp) evalStr(x *strLit, sc *Scope) (Value, *errs.Error) {
	if len(x.parts) == 1 && x.parts[0].expr == nil {
		return strVal(x.parts[0].lit), nil
	}
	var sb strings.Builder
	for _, p := range x.parts {
		if p.expr == nil {
			sb.WriteString(p.lit)
			continue
		}
		v, err := it.eval(p.expr, sc)
		if err != nil {
			return Value{}, err
		}
		if v.K == KList {
			return Value{}, errs.New(errs.Interp, "list")
		}
		sb.WriteString(v.text())
	}
	return strVal(sb.String()), nil
}

func (it *Interp) evalUnary(x *unary, sc *Scope) (Value, *errs.Error) {
	v, err := it.eval(x.x, sc)
	if err != nil {
		return Value{}, err
	}
	if x.op == "!" {
		if v.K != KBool {
			return Value{}, typeErr("operator !", mB, v.K)
		}
		return boolVal(v.I == 0), nil
	}
	if v.K != KInt {
		return Value{}, typeErr("operator -", mI, v.K)
	}
	return intVal(-v.I), nil
}

func (it *Interp) evalBinary(x *binary, sc *Scope) (Value, *errs.Error) {
	l, err := it.eval(x.l, sc)
	if err != nil {
		return Value{}, err
	}
	if x.op == "||" || x.op == "&&" {
		if l.K != KBool {
			return Value{}, typeErr("operator "+x.op, mB, l.K)
		}
		if (x.op == "||") == (l.I != 0) {
			return l, nil
		}
		r, err := it.eval(x.r, sc)
		if err != nil {
			return Value{}, err
		}
		if r.K != KBool {
			return Value{}, typeErr("operator "+x.op, mB, r.K)
		}
		return r, nil
	}
	r, err := it.eval(x.r, sc)
	if err != nil {
		return Value{}, err
	}
	switch x.op {
	case "==":
		return boolVal(Equal(l, r)), nil
	case "!=":
		return boolVal(!Equal(l, r)), nil
	case "<":
		return boolVal(Compare(l, r) < 0), nil
	case "<=":
		return boolVal(Compare(l, r) <= 0), nil
	case ">":
		return boolVal(Compare(l, r) > 0), nil
	case ">=":
		return boolVal(Compare(l, r) >= 0), nil
	case "++":
		if l.K != KList {
			return Value{}, typeErr("operator ++", mL, l.K)
		}
		if r.K != KList {
			return Value{}, typeErr("operator ++", mL, r.K)
		}
		out := make([]Value, 0, len(l.L)+len(r.L))
		out = append(out, l.L...)
		return listVal(append(out, r.L...)), nil
	case "~":
		if l.K != KStr {
			return Value{}, typeErr("operator ~", mS, l.K)
		}
		if r.K != KStr {
			return Value{}, typeErr("operator ~", mS, r.K)
		}
		return strVal(l.S + r.S), nil
	}
	// Integer arithmetic.
	if l.K != KInt {
		return Value{}, typeErr("operator "+x.op, mI, l.K)
	}
	if r.K != KInt {
		return Value{}, typeErr("operator "+x.op, mI, r.K)
	}
	switch x.op {
	case "+":
		return intVal(l.I + r.I), nil
	case "-":
		return intVal(l.I - r.I), nil
	case "*":
		return intVal(l.I * r.I), nil
	}
	if r.I == 0 {
		return Value{}, errs.Bare(errs.DivZero)
	}
	if x.op == "/" {
		return intVal(l.I / r.I), nil
	}
	return intVal(l.I % r.I), nil
}

func (it *Interp) evalIndex(x *index, sc *Scope) (Value, *errs.Error) {
	t, err := it.eval(x.x, sc)
	if err != nil {
		return Value{}, err
	}
	i, err := it.eval(x.i, sc)
	if err != nil {
		return Value{}, err
	}
	if i.K != KInt {
		return Value{}, typeErr("index", mI, i.K)
	}
	if t.K != KStr && t.K != KList {
		return Value{}, typeErr("index target", mS|mL, t.K)
	}
	n := int64(len(t.L))
	if t.K == KStr {
		n = int64(len(t.S))
	}
	k := i.I
	if k < 0 {
		k += n
	}
	if k < 0 || k >= n {
		return Value{}, argErr("fn", "index", "out of range")
	}
	if t.K == KStr {
		return strVal(t.S[k : k+1]), nil
	}
	return t.L[k], nil
}

func (it *Interp) evalCall(c *call, sc *Scope) (Value, *errs.Error) {
	fn := c.fn
	if fn == nil {
		return Value{}, errs.New(errs.UnknownFunc, "%s", c.name)
	}
	var buf [4]Value
	args := buf[:0]
	for _, a := range c.args {
		v, err := it.eval(a, sc)
		if err != nil {
			return Value{}, err
		}
		args = append(args, v)
	}
	if n := len(args); n < fn.min || n > fn.max {
		if fn.min == fn.max {
			return Value{}, errs.New(errs.Arity, "fn %s: expected %d, got %d", fn.name, fn.min, n)
		}
		return Value{}, errs.New(errs.Arity, "fn %s: expected %d-%d, got %d", fn.name, fn.min, fn.max, n)
	}
	for i, a := range args {
		m := fn.params[min(i, len(fn.params)-1)]
		if !m.has(a.K) {
			return Value{}, typeErr("fn "+fn.name+" argument "+itoa(i+1), m, a.K)
		}
	}
	return fn.run(it, args)
}
