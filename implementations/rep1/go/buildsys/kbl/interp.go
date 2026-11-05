// Package kbl implements the Kiln Build Language: lexing, parsing and
// evaluation of build files into a plan.Plan of steps, phony targets and
// default targets, including the 39 built-in functions.
package kbl

import (
	"strconv"
	"strings"

	"buildsys/command"
	"buildsys/kilnerr"
	"buildsys/plan"
	"buildsys/vfs"
)

// MaxRuleDepth is the maximum rule instantiation depth.
const MaxRuleDepth = 64

// MainFile is the root build file's workspace path.
const MainFile = "main.kiln"

type ruleDef struct {
	rule  *ruleStmt
	scope *scope
}

// Interp evaluates build files against a file system. One Interp evaluates
// one build; create a fresh one for each build.
type Interp struct {
	fs       *vfs.FS
	plan     *plan.Plan
	phonies  map[string]bool
	rules    map[string]*ruleDef
	includes []string
	depth    int
}

// Evaluate lexes, parses and executes main.kiln (and everything it includes)
// in a fresh root scope and returns the resulting plan. Reading the
// workspace is its only side effect.
func Evaluate(fs *vfs.FS) (p *plan.Plan, err *kilnerr.Error) {
	ip := &Interp{
		fs:      fs,
		plan:    &plan.Plan{},
		phonies: map[string]bool{},
		rules:   map[string]*ruleDef{},
	}
	defer func() {
		if r := recover(); r != nil {
			e, ok := r.(*kilnerr.Error)
			if !ok {
				panic(r)
			}
			p, err = nil, e
		}
	}()
	if !fs.Exists(MainFile) {
		return nil, kilnerr.New(kilnerr.NoBuildFile, MainFile)
	}
	ip.runFile(MainFile, newScope(nil))
	return ip.plan, nil
}

func raise(kind, detail string) { panic(kilnerr.New(kind, detail)) }

func typeErr(site, expected string, got Kind) {
	raise(kilnerr.Type, site+": expected "+expected+", got "+got.TypeName())
}

func (ip *Interp) runFile(path string, sc *scope) {
	content, _ := ip.fs.Read(path)
	stmts, err := parseSource(path, string(content))
	if err != nil {
		panic(err)
	}
	ip.includes = append(ip.includes, path)
	ip.exec(stmts, sc)
	ip.includes = ip.includes[:len(ip.includes)-1]
}

func (ip *Interp) exec(stmts []stmt, sc *scope) {
	for _, st := range stmts {
		ip.execOne(st, sc)
	}
}

func (ip *Interp) execOne(st stmt, sc *scope) {
	switch s := st.(type) {
	case *letStmt:
		v := ip.eval(s.e, sc)
		if _, dup := sc.vars[s.name]; dup {
			raise(kilnerr.Redefine, s.name)
		}
		sc.vars[s.name] = v
	case *setStmt:
		v := ip.eval(s.e, sc)
		for t := sc; t != nil; t = t.parent {
			if _, ok := t.vars[s.name]; ok {
				t.vars[s.name] = v
				return
			}
		}
		raise(kilnerr.SetUndefined, s.name)
	case *includeStmt:
		v := ip.eval(s.e, sc)
		if v.K != KStr {
			typeErr("include path", "str", v.K)
		}
		if !vfs.IsPath(v.S) {
			raise(kilnerr.BadPath, v.S)
		}
		if !ip.fs.Exists(v.S) {
			raise(kilnerr.IncludeMissing, v.S)
		}
		for _, p := range ip.includes {
			if p == v.S {
				raise(kilnerr.IncludeCycle, v.S)
			}
		}
		ip.runFile(v.S, sc)
	case *abortStmt:
		v := ip.eval(s.e, sc)
		if v.K != KStr {
			typeErr("abort message", "str", v.K)
		}
		raise(kilnerr.Abort, v.S)
	case *defaultStmt:
		v := ip.eval(s.e, sc)
		ip.plan.Defaults = append(ip.plan.Defaults, strList(v, "default")...)
	case *phonyStmt:
		v := ip.eval(s.e, sc)
		deps := strList(v, "phony "+s.name)
		for _, d := range deps {
			checkRef(d)
		}
		if ip.phonies[s.name] {
			raise(kilnerr.DupPhony, s.name)
		}
		ip.phonies[s.name] = true
		ip.plan.Phonies = append(ip.plan.Phonies, &plan.Phony{Name: s.name, Deps: deps})
	case *useStmt:
		ip.use(s, sc)
	case *whenStmt:
		for i, c := range s.conds {
			v := ip.eval(c, sc)
			if v.K != KBool {
				typeErr("when condition", "bool", v.K)
			}
			if v.I == 1 {
				ip.exec(s.bodies[i], newScope(sc))
				return
			}
		}
		if s.hasOther {
			ip.exec(s.otherwise, newScope(sc))
		}
	case *eachStmt:
		v := ip.eval(s.subject, sc)
		if v.K != KList {
			typeErr("each subject", "list", v.K)
		}
		for i, el := range v.L {
			ns := newScope(sc)
			ns.vars[s.name] = el
			if s.index != "" {
				ns.vars[s.index] = vInt(int64(i))
			}
			ip.exec(s.body, ns)
		}
	case *ruleStmt:
		if _, dup := ip.rules[s.name]; dup {
			raise(kilnerr.Redefine, s.name)
		}
		ip.rules[s.name] = &ruleDef{rule: s, scope: sc}
	case *stepStmt:
		ip.step(s, sc)
	default:
		panic("kbl: unknown statement")
	}
}

func (ip *Interp) use(s *useStmt, sc *scope) {
	rd, ok := ip.rules[s.name]
	if !ok {
		raise(kilnerr.UnknownRule, s.name)
	}
	if ip.depth+1 > MaxRuleDepth {
		raise(kilnerr.RuleRecursion, s.name)
	}
	vals := make([]Value, len(s.args))
	for i, a := range s.args {
		vals[i] = ip.eval(a.e, sc)
	}
	ns := newScope(rd.scope)
	params := rd.rule.params
	npos := 0
	for _, a := range s.args {
		if a.kw == "" {
			npos++
		}
	}
	if npos > len(params) {
		raise(kilnerr.Arity, "rule "+s.name+": expected "+itoa(len(params))+", got "+itoa(npos))
	}
	for i := 0; i < npos; i++ {
		ns.vars[params[i].name] = vals[i]
	}
	for i, a := range s.args {
		if a.kw == "" {
			continue
		}
		known := false
		for _, p := range params {
			if p.name == a.kw {
				known = true
				break
			}
		}
		if !known {
			raise(kilnerr.Arg, "rule "+s.name+": unknown argument "+a.kw)
		}
		if _, dup := ns.vars[a.kw]; dup {
			raise(kilnerr.Arg, "rule "+s.name+": duplicate argument "+a.kw)
		}
		ns.vars[a.kw] = vals[i]
	}
	for _, p := range params {
		if _, bound := ns.vars[p.name]; bound {
			continue
		}
		if p.def == nil {
			raise(kilnerr.Arg, "rule "+s.name+": missing argument "+p.name)
		}
		ns.vars[p.name] = ip.eval(p.def, ns)
	}
	ip.depth++
	ip.exec(rd.rule.body, ns)
	ip.depth--
}

// strList converts v to a list of strings for a strlist site.
func strList(v Value, site string) []string {
	switch v.K {
	case KStr:
		return []string{v.S}
	case KList:
		out := make([]string, len(v.L))
		for i, e := range v.L {
			if e.K != KStr {
				typeErr(site, "strlist", e.K)
			}
			out[i] = e.S
		}
		return out
	}
	typeErr(site, "strlist", v.K)
	return nil
}

func isIdentName(s string) bool {
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

// checkRef validates the shape of an `in`/`after`/phony dependency entry.
func checkRef(s string) {
	if strings.HasPrefix(s, "@") {
		if !isIdentName(s[1:]) {
			raise(kilnerr.BadPath, s)
		}
		return
	}
	if !vfs.IsPath(s) {
		raise(kilnerr.BadPath, s)
	}
}

func (ip *Interp) step(s *stepStmt, sc *scope) {
	var (
		outs, ins, after []string
		cost             int64
		hasCost          bool
		depfile          string
		hasDepfile       bool
		cmdName          string
		hasCmd           bool
		args             []command.Arg
		spec             *command.Spec
	)
	for _, f := range s.fields {
		switch f.kind {
		case "out", "in", "after":
			v := ip.eval(f.e, sc)
			l := strList(v, "field "+f.kind)
			switch f.kind {
			case "out":
				outs = append(outs, l...)
			case "in":
				ins = append(ins, l...)
			default:
				after = append(after, l...)
			}
		case "cost":
			if hasCost {
				raise(kilnerr.StepField, "duplicate cost")
			}
			v := ip.eval(f.e, sc)
			if v.K != KInt {
				typeErr("field cost", "int", v.K)
			}
			if v.I < 0 {
				raise(kilnerr.Arg, "field cost: negative")
			}
			cost, hasCost = v.I, true
		case "depfile":
			if hasDepfile {
				raise(kilnerr.StepField, "duplicate depfile")
			}
			v := ip.eval(f.e, sc)
			if v.K != KStr {
				typeErr("field depfile", "str", v.K)
			}
			depfile, hasDepfile = v.S, true
		case "cmd":
			if hasCmd {
				raise(kilnerr.StepField, "duplicate cmd")
			}
			sp, ok := command.Lookup(f.cmd)
			if !ok {
				raise(kilnerr.UnknownCmd, f.cmd)
			}
			vals := make([]Value, len(f.args))
			for i, a := range f.args {
				vals[i] = ip.eval(a, sc)
			}
			if len(vals) != len(sp.Args) {
				raise(kilnerr.Arity, "cmd "+f.cmd+": expected "+itoa(len(sp.Args))+", got "+itoa(len(vals)))
			}
			args = make([]command.Arg, len(vals))
			for i, v := range vals {
				want := sp.Args[i]
				site := "cmd " + f.cmd + " argument " + itoa(i+1)
				switch {
				case want == command.IntArg && v.K == KInt:
					args[i] = command.IntOf(v.I)
				case want == command.StrArg && v.K == KStr:
					args[i] = command.StrOf(v.S)
				default:
					typeErr(site, want.Name(), v.K)
				}
			}
			cmdName, spec, hasCmd = f.cmd, sp, true
		}
	}

	// Validation at the closing brace.
	if !hasCmd {
		raise(kilnerr.StepField, "missing cmd")
	}
	if len(outs) == 0 {
		raise(kilnerr.StepField, "missing out")
	}
	checkOut := func(p string) {
		if !vfs.IsPath(p) {
			raise(kilnerr.BadPath, p)
		}
		if !vfs.IsGenerated(p) {
			raise(kilnerr.OutputPath, p)
		}
	}
	for _, p := range outs {
		checkOut(p)
	}
	if hasDepfile {
		checkOut(depfile)
	}
	for _, p := range ins {
		checkRef(p)
	}
	for _, p := range after {
		checkRef(p)
	}
	fileIns := make([]string, 0, len(ins))
	for _, p := range ins {
		if !strings.HasPrefix(p, "@") {
			fileIns = append(fileIns, p)
		}
	}
	if !spec.FitsInputs(len(fileIns)) {
		raise(kilnerr.CmdShape, cmdName+": expected inputs "+spec.InputRange()+", got "+itoa(len(fileIns)))
	}
	if len(outs) != 1 {
		raise(kilnerr.CmdShape, cmdName+": expected outputs 1, got "+itoa(len(outs)))
	}
	if hasDepfile && !spec.Depfile {
		raise(kilnerr.CmdShape, cmdName+": depfile not allowed")
	}
	if !hasDepfile && spec.Depfile {
		raise(kilnerr.CmdShape, cmdName+": depfile required")
	}
	switch cmdName {
	case "replace":
		if args[0].Str == "" {
			raise(kilnerr.Arg, "cmd replace: empty pattern")
		}
	case "indent":
		if args[0].Int < 0 {
			raise(kilnerr.Arg, "cmd indent: negative")
		}
	}
	if !hasCost {
		cost = spec.DefaultCost
	}
	full := append(make([]string, 0, len(outs)+1), outs...)
	if hasDepfile {
		full = append(full, depfile)
	}
	ip.plan.Steps = append(ip.plan.Steps, &plan.Step{
		Serial:    len(ip.plan.Steps),
		Outs:      outs,
		Ins:       ins,
		After:     after,
		Depfile:   depfile,
		Cmd:       cmdName,
		Args:      args,
		Cost:      cost,
		FileIns:   fileIns,
		FullOuts:  full,
		CmdString: command.Canonical(cmdName, args),
	})
}

// ---- expressions ----

func (ip *Interp) eval(e expr, sc *scope) Value {
	switch x := e.(type) {
	case *intLit:
		return vInt(x.v)
	case *boolLit:
		return vBool(x.v)
	case *strLit:
		if len(x.parts) == 1 && !x.parts[0].isEx {
			return vStr(x.parts[0].lit)
		}
		var b strings.Builder
		for _, p := range x.parts {
			if !p.isEx {
				b.WriteString(p.lit)
				continue
			}
			v := ip.eval(p.e, sc)
			switch v.K {
			case KStr:
				b.WriteString(v.S)
			case KInt:
				b.WriteString(strconv.FormatInt(v.I, 10))
			case KBool:
				b.WriteString(boolText(v))
			default:
				raise(kilnerr.Interp, "list")
			}
		}
		return vStr(b.String())
	case *varRef:
		v, ok := sc.lookup(x.name)
		if !ok {
			raise(kilnerr.UnknownVar, x.name)
		}
		return v
	case *listLit:
		l := make([]Value, len(x.elems))
		for i, el := range x.elems {
			l[i] = ip.eval(el, sc)
		}
		return vList(l)
	case *unary:
		v := ip.eval(x.x, sc)
		if x.op == "!" {
			if v.K != KBool {
				typeErr("operator !", "bool", v.K)
			}
			return vBool(v.I == 0)
		}
		if v.K != KInt {
			typeErr("operator -", "int", v.K)
		}
		return vInt(-v.I)
	case *binary:
		return ip.binary(x, sc)
	case *indexExpr:
		xv := ip.eval(x.x, sc)
		iv := ip.eval(x.i, sc)
		if iv.K != KInt {
			typeErr("index", "int", iv.K)
		}
		switch xv.K {
		case KStr:
			i, ok := normIndex(iv.I, len(xv.S))
			if !ok {
				raise(kilnerr.Arg, "fn index: out of range")
			}
			return vStr(xv.S[i : i+1])
		case KList:
			i, ok := normIndex(iv.I, len(xv.L))
			if !ok {
				raise(kilnerr.Arg, "fn index: out of range")
			}
			return xv.L[i]
		}
		typeErr("index target", "str|list", xv.K)
	case *call:
		return ip.call(x, sc)
	}
	panic("kbl: unknown expression")
}

func boolText(v Value) string {
	if v.I == 1 {
		return "true"
	}
	return "false"
}

func normIndex(i int64, n int) (int, bool) {
	if i < 0 {
		i += int64(n)
	}
	if i < 0 || i >= int64(n) {
		return 0, false
	}
	return int(i), true
}

func (ip *Interp) binary(x *binary, sc *scope) Value {
	switch x.op {
	case "||", "&&":
		l := ip.eval(x.l, sc)
		if l.K != KBool {
			typeErr("operator "+x.op, "bool", l.K)
		}
		if (x.op == "||") == (l.I == 1) {
			return l
		}
		r := ip.eval(x.r, sc)
		if r.K != KBool {
			typeErr("operator "+x.op, "bool", r.K)
		}
		return r
	}
	l := ip.eval(x.l, sc)
	r := ip.eval(x.r, sc)
	site := "operator " + x.op
	need := func(k Kind) {
		if l.K != k {
			typeErr(site, k.TypeName(), l.K)
		}
		if r.K != k {
			typeErr(site, k.TypeName(), r.K)
		}
	}
	switch x.op {
	case "==":
		return vBool(Equal(l, r))
	case "!=":
		return vBool(!Equal(l, r))
	case "<":
		return vBool(Compare(l, r) < 0)
	case "<=":
		return vBool(Compare(l, r) <= 0)
	case ">":
		return vBool(Compare(l, r) > 0)
	case ">=":
		return vBool(Compare(l, r) >= 0)
	case "++":
		need(KList)
		out := make([]Value, 0, len(l.L)+len(r.L))
		out = append(out, l.L...)
		return vList(append(out, r.L...))
	case "~":
		need(KStr)
		return vStr(l.S + r.S)
	}
	need(KInt)
	switch x.op {
	case "+":
		return vInt(l.I + r.I)
	case "-":
		return vInt(l.I - r.I)
	case "*":
		return vInt(l.I * r.I)
	}
	if r.I == 0 {
		raise(kilnerr.DivZero, "")
	}
	if x.op == "/" {
		return vInt(l.I / r.I)
	}
	return vInt(l.I % r.I)
}

func (ip *Interp) call(c *call, sc *scope) Value {
	b, ok := builtins[c.name]
	if !ok {
		raise(kilnerr.UnknownFunc, c.name)
	}
	args := make([]Value, len(c.args))
	for i, a := range c.args {
		args[i] = ip.eval(a, sc)
	}
	if len(args) < b.minArgs || len(args) > b.maxArgs {
		want := itoa(b.minArgs)
		if b.minArgs != b.maxArgs {
			want += "-" + itoa(b.maxArgs)
		}
		raise(kilnerr.Arity, "fn "+c.name+": expected "+want+", got "+itoa(len(args)))
	}
	for i, a := range args {
		t := b.types[0]
		if i < len(b.types) {
			t = b.types[i]
		}
		if !typeAccepts(t, a.K) {
			typeErr("fn "+c.name+" argument "+itoa(i+1), t, a.K)
		}
	}
	return b.fn(ip, args)
}

// typeAccepts reports whether a value of kind k satisfies the type token t
// ("" accepts anything; otherwise "|"-separated type names).
func typeAccepts(t string, k Kind) bool {
	if t == "" {
		return true
	}
	name := k.TypeName()
	if t == name {
		return true
	}
	if strings.IndexByte(t, '|') < 0 {
		return false
	}
	for _, alt := range strings.Split(t, "|") {
		if alt == name {
			return true
		}
	}
	return false
}
