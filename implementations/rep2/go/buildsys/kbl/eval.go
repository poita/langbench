package kbl

import (
	"strconv"
	"strings"

	"buildsys/cmds"
	"buildsys/graph"
	"buildsys/kerr"
	"buildsys/vfs"
)

// MainFile is the workspace path of the root build file.
const MainFile = "main.kiln"

// MaxRuleDepth is the maximum rule instantiation depth.
const MaxRuleDepth = 64

// Scope is a lexical scope: a mutable variable map with a parent pointer.
type Scope struct {
	vars   map[string]Value
	parent *Scope
}

// NewScope returns an empty scope whose parent is parent (which may be nil).
func NewScope(parent *Scope) *Scope {
	return &Scope{vars: map[string]Value{}, parent: parent}
}

func (s *Scope) lookup(name string) (Value, bool) {
	for sc := s; sc != nil; sc = sc.parent {
		if v, ok := sc.vars[name]; ok {
			return v, true
		}
	}
	return Value{}, false
}

// Result is the outcome of evaluating a build: the steps in serial order, the
// phony targets in declaration order and the default target list.
type Result struct {
	Steps    []*graph.Step
	Phonies  []graph.Phony
	Defaults []string
}

type ruleDef struct {
	rule  Rule
	scope *Scope
}

// Evaluator runs KBL build files against a file system.
type Evaluator struct {
	fs       *vfs.FS
	res      Result
	phonies  map[string]bool
	rules    map[string]*ruleDef
	includes []string
	depth    int
}

// Evaluate lexes, parses and executes the build file at path (normally
// MainFile) and everything it includes. The returned error, when non-nil, is
// always a *kerr.Error.
func Evaluate(fs *vfs.FS, path string) (*Result, error) {
	ev := &Evaluator{fs: fs, phonies: map[string]bool{}, rules: map[string]*ruleDef{}}
	if err := ev.runFile(path, NewScope(nil)); err != nil {
		return nil, err
	}
	return &ev.res, nil
}

func (ev *Evaluator) runFile(path string, sc *Scope) error {
	f := ev.fs.Get(path)
	stmts, err := Parse(f.Content())
	if err != nil {
		if pe, ok := err.(*ParseError); ok {
			return kerr.New(kerr.Parse, "%s:%d", path, pe.Line)
		}
		return err
	}
	ev.includes = append(ev.includes, path)
	defer func() { ev.includes = ev.includes[:len(ev.includes)-1] }()
	return ev.execBlock(stmts, sc)
}

func (ev *Evaluator) execBlock(stmts []Stmt, sc *Scope) error {
	for _, s := range stmts {
		if err := ev.exec(s, sc); err != nil {
			return err
		}
	}
	return nil
}

func (ev *Evaluator) exec(s Stmt, sc *Scope) error {
	switch s := s.(type) {
	case Let:
		v, err := ev.eval(s.X, sc)
		if err != nil {
			return err
		}
		if _, dup := sc.vars[s.Name]; dup {
			return kerr.New(kerr.Redefine, "%s", s.Name)
		}
		sc.vars[s.Name] = v
	case Set:
		v, err := ev.eval(s.X, sc)
		if err != nil {
			return err
		}
		for t := sc; t != nil; t = t.parent {
			if _, ok := t.vars[s.Name]; ok {
				t.vars[s.Name] = v
				return nil
			}
		}
		return kerr.New(kerr.SetUndefined, "%s", s.Name)
	case Include:
		return ev.execInclude(s, sc)
	case Abort:
		v, err := ev.eval(s.X, sc)
		if err != nil {
			return err
		}
		if v.K != KStr {
			return typeErr("abort message", "str", v.K.String())
		}
		return kerr.New(kerr.Abort, "%s", v.S)
	case Default:
		v, err := ev.eval(s.X, sc)
		if err != nil {
			return err
		}
		list, err := strList(v, "default")
		if err != nil {
			return err
		}
		ev.res.Defaults = append(ev.res.Defaults, list...)
	case Phony:
		return ev.execPhony(s, sc)
	case When:
		for i, c := range s.Conds {
			v, err := ev.eval(c, sc)
			if err != nil {
				return err
			}
			if v.K != KBool {
				return typeErr("when condition", "bool", v.K.String())
			}
			if v.I != 0 {
				return ev.execBlock(s.Bodies[i], NewScope(sc))
			}
		}
		if s.HasElse {
			return ev.execBlock(s.Else, NewScope(sc))
		}
	case Each:
		v, err := ev.eval(s.X, sc)
		if err != nil {
			return err
		}
		if v.K != KList {
			return typeErr("each subject", "list", v.K.String())
		}
		for i, e := range v.L {
			inner := NewScope(sc)
			inner.vars[s.Name] = e
			if s.Index != "" {
				inner.vars[s.Index] = Int(int64(i))
			}
			if err := ev.execBlock(s.Body, inner); err != nil {
				return err
			}
		}
	case Rule:
		if _, dup := ev.rules[s.Name]; dup {
			return kerr.New(kerr.Redefine, "%s", s.Name)
		}
		ev.rules[s.Name] = &ruleDef{rule: s, scope: sc}
	case Use:
		return ev.execUse(s, sc)
	case StepStmt:
		return ev.execStep(s, sc)
	}
	return nil
}

func (ev *Evaluator) execInclude(s Include, sc *Scope) error {
	v, err := ev.eval(s.X, sc)
	if err != nil {
		return err
	}
	if v.K != KStr {
		return typeErr("include path", "str", v.K.String())
	}
	if !vfs.ValidPath(v.S) {
		return kerr.New(kerr.BadPath, "%s", v.S)
	}
	if !ev.fs.Exists(v.S) {
		return kerr.New(kerr.IncludeMissing, "%s", v.S)
	}
	for _, p := range ev.includes {
		if p == v.S {
			return kerr.New(kerr.IncludeCycle, "%s", v.S)
		}
	}
	return ev.runFile(v.S, sc)
}

func (ev *Evaluator) execPhony(s Phony, sc *Scope) error {
	v, err := ev.eval(s.X, sc)
	if err != nil {
		return err
	}
	deps, err := strList(v, "phony "+s.Name)
	if err != nil {
		return err
	}
	for _, d := range deps {
		if !validRef(d) {
			return kerr.New(kerr.BadPath, "%s", d)
		}
	}
	if ev.phonies[s.Name] {
		return kerr.New(kerr.DupPhony, "%s", s.Name)
	}
	ev.phonies[s.Name] = true
	ev.res.Phonies = append(ev.res.Phonies, graph.Phony{Name: s.Name, Deps: deps})
	return nil
}

func (ev *Evaluator) execUse(s Use, sc *Scope) error {
	def, ok := ev.rules[s.Rule]
	if !ok {
		return kerr.New(kerr.UnknownRule, "%s", s.Rule)
	}
	if ev.depth+1 > MaxRuleDepth {
		return kerr.New(kerr.RuleRecursion, "%s", s.Rule)
	}
	vals := make([]Value, len(s.Args))
	for i, a := range s.Args {
		v, err := ev.eval(a.X, sc)
		if err != nil {
			return err
		}
		vals[i] = v
	}
	params := def.rule.Params
	inner := NewScope(def.scope)
	npos := 0
	for _, a := range s.Args {
		if a.Name == "" {
			npos++
		}
	}
	if npos > len(params) {
		return kerr.New(kerr.Arity, "rule %s: expected %d, got %d", s.Rule, len(params), npos)
	}
	bound := make(map[string]bool, len(params))
	pi := 0
	for i, a := range s.Args {
		if a.Name != "" {
			continue
		}
		inner.vars[params[pi].Name] = vals[i]
		bound[params[pi].Name] = true
		pi++
	}
	for i, a := range s.Args {
		if a.Name == "" {
			continue
		}
		known := false
		for _, p := range params {
			if p.Name == a.Name {
				known = true
				break
			}
		}
		if !known {
			return kerr.New(kerr.Arg, "rule %s: unknown argument %s", s.Rule, a.Name)
		}
		if bound[a.Name] {
			return kerr.New(kerr.Arg, "rule %s: duplicate argument %s", s.Rule, a.Name)
		}
		inner.vars[a.Name] = vals[i]
		bound[a.Name] = true
	}
	for _, p := range params {
		if bound[p.Name] {
			continue
		}
		if p.Default == nil {
			return kerr.New(kerr.Arg, "rule %s: missing argument %s", s.Rule, p.Name)
		}
		v, err := ev.eval(p.Default, inner)
		if err != nil {
			return err
		}
		inner.vars[p.Name] = v
	}
	ev.depth++
	defer func() { ev.depth-- }()
	return ev.execBlock(def.rule.Body, inner)
}

func (ev *Evaluator) execStep(s StepStmt, sc *Scope) error {
	st := &graph.Step{Serial: len(ev.res.Steps), Cost: -1}
	var hasCmd, hasCost bool
	for _, f := range s.Fields {
		switch f.Kind {
		case "out", "in", "after":
			v, err := ev.eval(f.X, sc)
			if err != nil {
				return err
			}
			list, err := strList(v, "field "+f.Kind)
			if err != nil {
				return err
			}
			switch f.Kind {
			case "out":
				st.Outputs = append(st.Outputs, list...)
			case "in":
				st.Inputs = append(st.Inputs, list...)
			default:
				st.After = append(st.After, list...)
			}
		case "cost":
			if hasCost {
				return kerr.New(kerr.StepField, "duplicate cost")
			}
			v, err := ev.eval(f.X, sc)
			if err != nil {
				return err
			}
			if v.K != KInt {
				return typeErr("field cost", "int", v.K.String())
			}
			if v.I < 0 {
				return kerr.New(kerr.Arg, "field cost: negative")
			}
			hasCost = true
			st.Cost = v.I
		case "depfile":
			if st.HasDepfile {
				return kerr.New(kerr.StepField, "duplicate depfile")
			}
			v, err := ev.eval(f.X, sc)
			if err != nil {
				return err
			}
			if v.K != KStr {
				return typeErr("field depfile", "str", v.K.String())
			}
			st.HasDepfile, st.Depfile = true, v.S
		case "cmd":
			if hasCmd {
				return kerr.New(kerr.StepField, "duplicate cmd")
			}
			inv, spec, err := ev.evalCmd(f, sc)
			if err != nil {
				return err
			}
			hasCmd = true
			st.Cmd, st.Spec = inv, spec
		}
	}
	if err := validateStep(st, hasCmd); err != nil {
		return err
	}
	if !hasCost {
		st.Cost = st.Spec.DefaultCost
	}
	st.Finish()
	ev.res.Steps = append(ev.res.Steps, st)
	return nil
}

func (ev *Evaluator) evalCmd(f StepField, sc *Scope) (cmds.Invocation, *cmds.Spec, error) {
	spec, ok := cmds.Lookup(f.Cmd)
	if !ok {
		return cmds.Invocation{}, nil, kerr.New(kerr.UnknownCmd, "%s", f.Cmd)
	}
	vals := make([]Value, len(f.Args))
	for i, a := range f.Args {
		v, err := ev.eval(a, sc)
		if err != nil {
			return cmds.Invocation{}, nil, err
		}
		vals[i] = v
	}
	if len(vals) != len(spec.Params) {
		return cmds.Invocation{}, nil, kerr.New(kerr.Arity, "cmd %s: expected %d, got %d", f.Cmd, len(spec.Params), len(vals))
	}
	inv := cmds.Invocation{Name: f.Cmd, Args: make([]cmds.Arg, len(vals))}
	for i, v := range vals {
		want := spec.Params[i]
		if (want == cmds.StrArg && v.K != KStr) || (want == cmds.IntArg && v.K != KInt) {
			return cmds.Invocation{}, nil, typeErr("cmd "+f.Cmd+" argument "+strconv.Itoa(i+1), want.String(), v.K.String())
		}
		if want == cmds.StrArg {
			inv.Args[i] = cmds.Arg{Kind: cmds.StrArg, Str: v.S}
		} else {
			inv.Args[i] = cmds.Arg{Kind: cmds.IntArg, Int: v.I}
		}
	}
	return inv, spec, nil
}

// validateStep performs the checks made when a step block closes.
func validateStep(st *graph.Step, hasCmd bool) error {
	if !hasCmd {
		return kerr.New(kerr.StepField, "missing cmd")
	}
	if len(st.Outputs) == 0 {
		return kerr.New(kerr.StepField, "missing out")
	}
	outs := st.Outputs
	if st.HasDepfile {
		outs = append(append([]string(nil), outs...), st.Depfile)
	}
	for _, p := range outs {
		if !vfs.ValidPath(p) {
			return kerr.New(kerr.BadPath, "%s", p)
		}
		if !vfs.IsGenerated(p) {
			return kerr.New(kerr.OutputPath, "%s", p)
		}
	}
	for _, list := range [][]string{st.Inputs, st.After} {
		for _, p := range list {
			if !validRef(p) {
				return kerr.New(kerr.BadPath, "%s", p)
			}
		}
	}
	files := 0
	for _, in := range st.Inputs {
		if !strings.HasPrefix(in, "@") {
			files++
		}
	}
	spec := st.Spec
	if files < spec.MinInputs || (spec.MaxInputs >= 0 && files > spec.MaxInputs) {
		return kerr.New(kerr.CmdShape, "%s: expected inputs %s, got %d", spec.Name, spec.InputRange(), files)
	}
	if len(st.Outputs) != 1 {
		return kerr.New(kerr.CmdShape, "%s: expected outputs 1, got %d", spec.Name, len(st.Outputs))
	}
	if spec.Depfile && !st.HasDepfile {
		return kerr.New(kerr.CmdShape, "%s: depfile required", spec.Name)
	}
	if !spec.Depfile && st.HasDepfile {
		return kerr.New(kerr.CmdShape, "%s: depfile not allowed", spec.Name)
	}
	if err := spec.CheckArgs(st.Cmd); err != nil {
		return err
	}
	return nil
}

// validRef reports whether s is "@" plus an identifier, or a workspace path.
func validRef(s string) bool {
	if strings.HasPrefix(s, "@") {
		return isIdentShaped(s[1:])
	}
	return vfs.ValidPath(s)
}

func isIdentShaped(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && c >= '0' && c <= '9' {
			continue
		}
		return false
	}
	return true
}

// strList interprets v as a str or a list of str.
func strList(v Value, site string) ([]string, error) {
	switch v.K {
	case KStr:
		return []string{v.S}, nil
	case KList:
		out := make([]string, len(v.L))
		for i, e := range v.L {
			if e.K != KStr {
				return nil, typeErr(site, "strlist", e.K.String())
			}
			out[i] = e.S
		}
		return out, nil
	}
	return nil, typeErr(site, "strlist", v.K.String())
}

// ---- expressions ----

func (ev *Evaluator) eval(e Expr, sc *Scope) (Value, error) {
	switch e := e.(type) {
	case IntLit:
		return Int(e.V), nil
	case BoolLit:
		return Bool(e.V), nil
	case StrLit:
		return ev.evalString(e, sc)
	case VarRef:
		v, ok := sc.lookup(e.Name)
		if !ok {
			return Value{}, kerr.New(kerr.UnknownVar, "%s", e.Name)
		}
		return v, nil
	case ListLit:
		out := make([]Value, len(e.Elems))
		for i, x := range e.Elems {
			v, err := ev.eval(x, sc)
			if err != nil {
				return Value{}, err
			}
			out[i] = v
		}
		return List(out), nil
	case Unary:
		return ev.evalUnary(e, sc)
	case Binary:
		return ev.evalBinary(e, sc)
	case Call:
		return ev.evalCall(e, sc)
	case Index:
		return ev.evalIndex(e, sc)
	}
	panic("kbl: unknown expression node")
}

func (ev *Evaluator) evalString(e StrLit, sc *Scope) (Value, error) {
	if len(e.Parts) == 1 && e.Parts[0].X == nil {
		return Str(e.Parts[0].Lit), nil
	}
	var b strings.Builder
	for _, p := range e.Parts {
		if p.X == nil {
			b.WriteString(p.Lit)
			continue
		}
		v, err := ev.eval(p.X, sc)
		if err != nil {
			return Value{}, err
		}
		if v.K == KList {
			return Value{}, kerr.New(kerr.Interp, "list")
		}
		b.WriteString(v.Text())
	}
	return Str(b.String()), nil
}

func (ev *Evaluator) evalUnary(e Unary, sc *Scope) (Value, error) {
	v, err := ev.eval(e.X, sc)
	if err != nil {
		return Value{}, err
	}
	if e.Op == "!" {
		if v.K != KBool {
			return Value{}, typeErr("operator !", "bool", v.K.String())
		}
		return Bool(v.I == 0), nil
	}
	if v.K != KInt {
		return Value{}, typeErr("operator -", "int", v.K.String())
	}
	return Int(-v.I), nil
}

func (ev *Evaluator) evalBinary(e Binary, sc *Scope) (Value, error) {
	l, err := ev.eval(e.L, sc)
	if err != nil {
		return Value{}, err
	}
	if e.Op == "||" || e.Op == "&&" {
		if l.K != KBool {
			return Value{}, typeErr("operator "+e.Op, "bool", l.K.String())
		}
		if (e.Op == "||") == (l.I != 0) {
			return l, nil // short circuit
		}
		r, err := ev.eval(e.R, sc)
		if err != nil {
			return Value{}, err
		}
		if r.K != KBool {
			return Value{}, typeErr("operator "+e.Op, "bool", r.K.String())
		}
		return r, nil
	}
	r, err := ev.eval(e.R, sc)
	if err != nil {
		return Value{}, err
	}
	switch e.Op {
	case "==":
		return Bool(Equal(l, r)), nil
	case "!=":
		return Bool(!Equal(l, r)), nil
	case "<":
		return Bool(Compare(l, r) < 0), nil
	case "<=":
		return Bool(Compare(l, r) <= 0), nil
	case ">":
		return Bool(Compare(l, r) > 0), nil
	case ">=":
		return Bool(Compare(l, r) >= 0), nil
	}
	want := KInt
	switch e.Op {
	case "++":
		want = KList
	case "~":
		want = KStr
	}
	if l.K != want {
		return Value{}, typeErr("operator "+e.Op, want.String(), l.K.String())
	}
	if r.K != want {
		return Value{}, typeErr("operator "+e.Op, want.String(), r.K.String())
	}
	switch e.Op {
	case "++":
		out := make([]Value, 0, len(l.L)+len(r.L))
		out = append(append(out, l.L...), r.L...)
		return List(out), nil
	case "~":
		return Str(l.S + r.S), nil
	case "+":
		return Int(l.I + r.I), nil
	case "-":
		return Int(l.I - r.I), nil
	case "*":
		return Int(l.I * r.I), nil
	}
	if r.I == 0 {
		return Value{}, kerr.New(kerr.DivZero, "")
	}
	if e.Op == "/" {
		return Int(l.I / r.I), nil
	}
	return Int(l.I % r.I), nil
}

func (ev *Evaluator) evalIndex(e Index, sc *Scope) (Value, error) {
	x, err := ev.eval(e.X, sc)
	if err != nil {
		return Value{}, err
	}
	i, err := ev.eval(e.I, sc)
	if err != nil {
		return Value{}, err
	}
	if i.K != KInt {
		return Value{}, typeErr("index", "int", i.K.String())
	}
	if x.K != KStr && x.K != KList {
		return Value{}, typeErr("index target", "str|list", x.K.String())
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
		return Str(x.S[idx : idx+1]), nil
	}
	return x.L[idx], nil
}

func (ev *Evaluator) evalCall(e Call, sc *Scope) (Value, error) {
	b, ok := builtins[e.Name]
	if !ok {
		return Value{}, kerr.New(kerr.UnknownFunc, "%s", e.Name)
	}
	args := make([]Value, len(e.Args))
	for i, a := range e.Args {
		v, err := ev.eval(a, sc)
		if err != nil {
			return Value{}, err
		}
		args[i] = v
	}
	if len(args) < b.min || len(args) > b.max {
		if b.min == b.max {
			return Value{}, kerr.New(kerr.Arity, "fn %s: expected %d, got %d", e.Name, b.min, len(args))
		}
		return Value{}, kerr.New(kerr.Arity, "fn %s: expected %d-%d, got %d", e.Name, b.min, b.max, len(args))
	}
	for i, a := range args {
		mask := b.params[min(i, len(b.params)-1)]
		if mask&kindBit(a.K) == 0 {
			return Value{}, typeErr("fn "+e.Name+" argument "+strconv.Itoa(i+1), typeToken(mask), a.K.String())
		}
	}
	return b.fn(ev, args)
}
