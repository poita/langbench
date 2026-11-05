// Package kbl implements the Kiln Build Language: a lexer, a parser and a
// tree-walking evaluator that turns build files into a plan.Build.
package kbl

import (
	"strconv"
	"strings"

	"buildsys/cmds"
	"buildsys/diag"
	"buildsys/plan"
	"buildsys/vfs"
)

// MaxRuleDepth is the maximum rule instantiation depth.
const MaxRuleDepth = 64

// Scope maps names to values and links to its parent scope.
type Scope struct {
	vars   map[string]Value
	parent *Scope
}

// NewScope returns a scope whose parent is parent (which may be nil).
func NewScope(parent *Scope) *Scope { return &Scope{parent: parent} }

// Lookup finds name in the scope or its ancestors.
func (s *Scope) Lookup(name string) (Value, bool) {
	for ; s != nil; s = s.parent {
		if v, ok := s.vars[name]; ok {
			return v, true
		}
	}
	return Value{}, false
}

func (s *Scope) bound(name string) bool { _, ok := s.vars[name]; return ok }

func (s *Scope) define(name string, v Value) {
	if s.vars == nil {
		s.vars = make(map[string]Value, 4)
	}
	s.vars[name] = v
}

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
	stmt  *RuleStmt
	scope *Scope
}

type interp struct {
	fs       *vfs.FS
	build    *plan.Build
	rules    map[string]*rule
	incStack []string
	depth    int
}

// Evaluate runs the build file at root (normally "main.kiln") and everything
// it includes against fs, and returns the resulting build description. The
// error, if any, is a *diag.Error.
func Evaluate(fs *vfs.FS, root string) (b *plan.Build, err error) {
	in := &interp{fs: fs, build: plan.NewBuild(), rules: map[string]*rule{}}
	defer func() {
		if r := recover(); r != nil {
			if de, ok := r.(*diag.Error); ok {
				b, err = nil, de
				return
			}
			panic(r)
		}
	}()
	in.runFile(root, NewScope(nil))
	return in.build, nil
}

func (in *interp) runFile(path string, sc *Scope) {
	content, _ := in.fs.Read(path)
	file, err := Parse(string(content))
	if err != nil {
		panic(diag.New(diag.Parse, "%s:%d", path, err.(*SyntaxError).Line))
	}
	in.incStack = append(in.incStack, path)
	in.exec(file.Body, sc)
	in.incStack = in.incStack[:len(in.incStack)-1]
}

// strList interprets v as a str or a list of str for the named site.
func strList(site string, v Value) []string {
	switch v.Kind {
	case KindStr:
		return []string{v.S}
	case KindList:
		out := make([]string, len(v.L))
		for i, e := range v.L {
			if e.Kind != KindStr {
				panic(typeErr(site, "strlist", e.Kind))
			}
			out[i] = e.S
		}
		return out
	}
	panic(typeErr(site, "strlist", v.Kind))
}

func (in *interp) exec(stmts []Stmt, sc *Scope) {
	for _, s := range stmts {
		switch s := s.(type) {
		case *LetStmt:
			v := in.eval(s.X, sc)
			if sc.bound(s.Name) {
				panic(diag.New(diag.Redefine, "%s", s.Name))
			}
			sc.define(s.Name, v)
		case *SetStmt:
			v := in.eval(s.X, sc)
			if !sc.assign(s.Name, v) {
				panic(diag.New(diag.SetUndefined, "%s", s.Name))
			}
		case *IncludeStmt:
			in.include(in.eval(s.X, sc), sc)
		case *AbortStmt:
			v := in.eval(s.X, sc)
			if v.Kind != KindStr {
				panic(typeErr("abort message", "str", v.Kind))
			}
			panic(diag.New(diag.Abort, "%s", v.S))
		case *DefaultStmt:
			in.build.AddDefault(strList("default", in.eval(s.X, sc))...)
		case *PhonyStmt:
			deps := strList("phony "+s.Name, in.eval(s.X, sc))
			for _, d := range deps {
				if err := plan.CheckRef(d); err != nil {
					panic(err)
				}
			}
			if err := in.build.AddPhony(s.Name, deps); err != nil {
				panic(err)
			}
		case *WhenStmt:
			in.execWhen(s, sc)
		case *EachStmt:
			in.execEach(s, sc)
		case *RuleStmt:
			if _, dup := in.rules[s.Name]; dup {
				panic(diag.New(diag.Redefine, "%s", s.Name))
			}
			in.rules[s.Name] = &rule{stmt: s, scope: sc}
		case *UseStmt:
			in.execUse(s, sc)
		case *StepStmt:
			in.execStep(s, sc)
		}
	}
}

func (in *interp) include(v Value, sc *Scope) {
	if v.Kind != KindStr {
		panic(typeErr("include path", "str", v.Kind))
	}
	if !vfs.IsWorkspacePath(v.S) {
		panic(diag.New(diag.BadPath, "%s", v.S))
	}
	if !in.fs.Exists(v.S) {
		panic(diag.New(diag.IncludeMissing, "%s", v.S))
	}
	for _, p := range in.incStack {
		if p == v.S {
			panic(diag.New(diag.IncludeCycle, "%s", v.S))
		}
	}
	in.runFile(v.S, sc)
}

func (in *interp) execWhen(s *WhenStmt, sc *Scope) {
	for _, br := range s.Branches {
		c := in.eval(br.Cond, sc)
		if c.Kind != KindBool {
			panic(typeErr("when condition", "bool", c.Kind))
		}
		if c.I != 0 {
			in.exec(br.Body, NewScope(sc))
			return
		}
	}
	if s.Else != nil {
		in.exec(s.Else.Body, NewScope(sc))
	}
}

func (in *interp) execEach(s *EachStmt, sc *Scope) {
	subject := in.eval(s.X, sc)
	if subject.Kind != KindList {
		panic(typeErr("each subject", "list", subject.Kind))
	}
	for i, el := range subject.L {
		ns := NewScope(sc)
		if s.Index != "" {
			ns.define(s.Index, intVal(int64(i)))
		}
		ns.define(s.Name, el)
		in.exec(s.Body, ns)
	}
}

func (in *interp) execUse(s *UseStmt, sc *Scope) {
	r, ok := in.rules[s.Rule]
	if !ok {
		panic(diag.New(diag.UnknownRule, "%s", s.Rule))
	}
	if in.depth+1 > MaxRuleDepth {
		panic(diag.New(diag.RuleRecursion, "%s", s.Rule))
	}
	vals := make([]Value, len(s.Args))
	for i, a := range s.Args {
		vals[i] = in.eval(a.X, sc)
	}
	params := r.stmt.Params
	ns := NewScope(r.scope)
	npos := 0
	for _, a := range s.Args {
		if a.Name == "" {
			npos++
		}
	}
	if npos > len(params) {
		panic(diag.New(diag.Arity, "rule %s: expected %d, got %d", s.Rule, len(params), npos))
	}
	bound := make([]bool, len(params))
	for i, a := range s.Args {
		if a.Name != "" {
			continue
		}
		ns.define(params[i].Name, vals[i])
		bound[i] = true
	}
	for i, a := range s.Args {
		if a.Name == "" {
			continue
		}
		idx := -1
		for j, p := range params {
			if p.Name == a.Name {
				idx = j
				break
			}
		}
		if idx < 0 {
			panic(diag.New(diag.Arg, "rule %s: unknown argument %s", s.Rule, a.Name))
		}
		if bound[idx] {
			panic(diag.New(diag.Arg, "rule %s: duplicate argument %s", s.Rule, a.Name))
		}
		ns.define(a.Name, vals[i])
		bound[idx] = true
	}
	for i, p := range params {
		if bound[i] {
			continue
		}
		if p.Default == nil {
			panic(diag.New(diag.Arg, "rule %s: missing argument %s", s.Rule, p.Name))
		}
		ns.define(p.Name, in.eval(p.Default, ns))
	}
	in.depth++
	in.exec(r.stmt.Body, ns)
	in.depth--
}

func (in *interp) execStep(s *StepStmt, sc *Scope) {
	d := &plan.Draft{}
	for _, f := range s.Fields {
		switch f.Kind {
		case "out":
			d.Outs = append(d.Outs, strList("field out", in.eval(f.X, sc))...)
		case "in":
			d.Ins = append(d.Ins, strList("field in", in.eval(f.X, sc))...)
		case "after":
			d.Afters = append(d.Afters, strList("field after", in.eval(f.X, sc))...)
		case "cost":
			if d.HasCost {
				panic(diag.New(diag.StepField, "duplicate cost"))
			}
			v := in.eval(f.X, sc)
			if v.Kind != KindInt {
				panic(typeErr("field cost", "int", v.Kind))
			}
			if v.I < 0 {
				panic(diag.New(diag.Arg, "field cost: negative"))
			}
			d.Cost, d.HasCost = v.I, true
		case "depfile":
			if d.HasDepfile {
				panic(diag.New(diag.StepField, "duplicate depfile"))
			}
			v := in.eval(f.X, sc)
			if v.Kind != KindStr {
				panic(typeErr("field depfile", "str", v.Kind))
			}
			d.Depfile, d.HasDepfile = v.S, true
		case "cmd":
			if d.Cmd != nil {
				panic(diag.New(diag.StepField, "duplicate cmd"))
			}
			d.Cmd = in.evalCmd(f, sc)
		}
	}
	step, err := d.Finish()
	if err != nil {
		panic(err)
	}
	in.build.AddStep(step)
}

func (in *interp) evalCmd(f StepField, sc *Scope) *cmds.Command {
	spec := cmds.Lookup(f.CmdName)
	if spec == nil {
		panic(diag.New(diag.UnknownCmd, "%s", f.CmdName))
	}
	vals := make([]Value, len(f.Args))
	for i, a := range f.Args {
		vals[i] = in.eval(a, sc)
	}
	if len(vals) != len(spec.Args) {
		panic(diag.New(diag.Arity, "cmd %s: expected %d, got %d", spec.Name, len(spec.Args), len(vals)))
	}
	c := &cmds.Command{Spec: spec, Args: make([]cmds.Arg, len(vals))}
	for i, v := range vals {
		want := spec.Args[i]
		site := "cmd " + spec.Name + " argument " + strconv.Itoa(i+1)
		switch {
		case want == cmds.ArgStr && v.Kind == KindStr:
			c.Args[i] = cmds.Arg{Str: v.S}
		case want == cmds.ArgInt && v.Kind == KindInt:
			c.Args[i] = cmds.Arg{IsInt: true, Int: v.I}
		default:
			panic(typeErr(site, want.TypeName(), v.Kind))
		}
	}
	return c
}

// ---- expressions ----

func (in *interp) eval(e Expr, sc *Scope) Value {
	switch e := e.(type) {
	case *LitExpr:
		return e.Val
	case *TemplateExpr:
		var b strings.Builder
		for _, p := range e.Parts {
			if p.Expr == nil {
				b.WriteString(p.Lit)
				continue
			}
			s, ok := in.eval(p.Expr, sc).Text()
			if !ok {
				panic(diag.New(diag.Interp, "list"))
			}
			b.WriteString(s)
		}
		return strVal(b.String())
	case *VarExpr:
		v, ok := sc.Lookup(e.Name)
		if !ok {
			panic(diag.New(diag.UnknownVar, "%s", e.Name))
		}
		return v
	case *ListExpr:
		out := make([]Value, len(e.Elems))
		for i, x := range e.Elems {
			out[i] = in.eval(x, sc)
		}
		return listVal(out)
	case *UnaryExpr:
		v := in.eval(e.X, sc)
		if e.Op == "!" {
			need("operator !", tBool, v)
			return boolVal(v.I == 0)
		}
		need("operator -", tInt, v)
		return intVal(-v.I)
	case *BinaryExpr:
		return in.evalBinary(e, sc)
	case *CallExpr:
		if e.Fn == nil {
			panic(diag.New(diag.UnknownFunc, "%s", e.Name))
		}
		args := make([]Value, len(e.Args))
		for i, a := range e.Args {
			args[i] = in.eval(a, sc)
		}
		return e.Fn.call(in, args)
	case *IndexExpr:
		x := in.eval(e.X, sc)
		i := in.eval(e.I, sc)
		need("index", tInt, i)
		need("index target", tStrList, x)
		n := int64(len(x.L))
		if x.Kind == KindStr {
			n = int64(len(x.S))
		}
		idx := i.I
		if idx < 0 {
			idx += n
		}
		if idx < 0 || idx >= n {
			panic(argErr("index", "out of range"))
		}
		if x.Kind == KindStr {
			return strVal(x.S[idx : idx+1])
		}
		return x.L[idx]
	}
	panic("kbl: unknown expression node")
}

func need(site string, t typeSpec, v Value) {
	if !t.accepts(v.Kind) {
		panic(typeErr(site, t.name, v.Kind))
	}
}

func (in *interp) evalBinary(e *BinaryExpr, sc *Scope) Value {
	site := "operator " + e.Op
	if e.Op == "||" || e.Op == "&&" {
		l := in.eval(e.L, sc)
		need(site, tBool, l)
		if (e.Op == "||") == (l.I != 0) {
			return l
		}
		r := in.eval(e.R, sc)
		need(site, tBool, r)
		return r
	}
	l := in.eval(e.L, sc)
	r := in.eval(e.R, sc)
	switch e.Op {
	case "==":
		return boolVal(Equal(l, r))
	case "!=":
		return boolVal(!Equal(l, r))
	case "<":
		return boolVal(Compare(l, r) < 0)
	case "<=":
		return boolVal(Compare(l, r) <= 0)
	case ">":
		return boolVal(Compare(l, r) > 0)
	case ">=":
		return boolVal(Compare(l, r) >= 0)
	case "++":
		need(site, tList, l)
		need(site, tList, r)
		out := make([]Value, 0, len(l.L)+len(r.L))
		out = append(out, l.L...)
		return listVal(append(out, r.L...))
	case "~":
		need(site, tStr, l)
		need(site, tStr, r)
		return strVal(l.S + r.S)
	}
	need(site, tInt, l)
	need(site, tInt, r)
	switch e.Op {
	case "+":
		return intVal(l.I + r.I)
	case "-":
		return intVal(l.I - r.I)
	case "*":
		return intVal(l.I * r.I)
	}
	if r.I == 0 {
		panic(diag.Bare(diag.DivZero))
	}
	if e.Op == "/" {
		return intVal(l.I / r.I)
	}
	return intVal(l.I % r.I)
}
