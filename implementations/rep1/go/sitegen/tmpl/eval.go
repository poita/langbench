package tmpl

import "strings"

// scope is a lexical scope: either the root (backed by a Dict) or a small
// array of bindings searched linearly.
type scope struct {
	parent *scope
	root   *Dict
	names  []string
	vals   []Value
}

func newScope(parent *scope) *scope { return &scope{parent: parent} }

func (s *scope) set(name string, v Value) {
	for i, n := range s.names {
		if n == name {
			s.vals[i] = v
			return
		}
	}
	s.names = append(s.names, name)
	s.vals = append(s.vals, v)
}

func (s *scope) lookup(name string) (Value, bool) {
	for sc := s; sc != nil; sc = sc.parent {
		if sc.root != nil {
			if v, ok := sc.root.Get(name); ok {
				return v, true
			}
			continue
		}
		for i, n := range sc.names {
			if n == name {
				return sc.vals[i], true
			}
		}
	}
	return nil, false
}

// macroVal is a macro bound in a scope; it remembers its defining scope.
type macroVal struct {
	def   *macroDef
	scope *scope
	rc    *renderCtx
}

// superRef is the value of "super" inside a block body.
type superRef struct {
	rc    *renderCtx
	name  string
	index int // index in the block chain of the body being rendered
}

type rangeFn struct{}

// renderCtx is the state of one template rendering (the main template or one
// include): the block chains and the template scope.
type renderCtx struct {
	e        *Engine
	chains   map[string][]*blockDef
	tscope   *scope
	pending  *template // parent template to run once the current body finishes
	suppress bool      // after extends: only set and macro take effect
}

// renderTemplate renders t with a fresh template scope below parent,
// appending to out.
func (e *Engine) renderTemplate(t *template, parent *scope, out *strings.Builder) {
	rc := &renderCtx{e: e, chains: make(map[string][]*blockDef, len(t.blocks)), tscope: newScope(parent)}
	for name, b := range t.blocks {
		rc.chains[name] = []*blockDef{b}
	}
	for cur := t; cur != nil; cur = rc.pending {
		rc.pending, rc.suppress = nil, false
		rc.execTop(cur.body, out)
	}
}

// execTop runs a template's top-level statements in the template scope.
func (rc *renderCtx) execTop(body []stmt, out *strings.Builder) {
	for _, s := range body {
		if rc.suppress {
			switch s := s.(type) {
			case *setStmt:
				rc.tscope.set(s.name, rc.eval(s.x, rc.tscope))
			case *macroDef:
				rc.tscope.set(s.name, &macroVal{def: s, scope: rc.tscope, rc: rc})
			}
			continue
		}
		if ex, ok := s.(*extendsStmt); ok {
			rc.extend(ex)
			continue
		}
		rc.exec(s, rc.tscope, out)
	}
}

func (rc *renderCtx) extend(ex *extendsStmt) {
	parent := rc.e.load(rc.templateName(rc.eval(ex.x, rc.tscope)))
	for name, b := range parent.blocks {
		rc.chains[name] = append(rc.chains[name], b)
	}
	rc.pending = parent
	rc.suppress = true
}

// templateName checks the value of an include/extends expression.
func (rc *renderCtx) templateName(v Value) string {
	if IsUndefined(v) {
		fail(UndefinedError, "undefined template name")
	}
	name, ok := v.(string)
	if !ok {
		fail(TypeError, "template name must be a string")
	}
	return name
}

func (rc *renderCtx) execBody(body []stmt, sc *scope, out *strings.Builder) {
	for _, s := range body {
		rc.exec(s, sc, out)
	}
}

func (rc *renderCtx) exec(s stmt, sc *scope, out *strings.Builder) {
	switch s := s.(type) {
	case *textStmt:
		out.WriteString(s.text)
	case *printStmt:
		v := rc.eval(s.x, sc)
		if IsUndefined(v) {
			fail(UndefinedError, "cannot print an undefined value")
		}
		writeValue(out, v, false)
	case *ifStmt:
		for i, cond := range s.conds {
			if rc.test(cond, sc) {
				rc.execBody(s.bodies[i], sc, out)
				return
			}
		}
		rc.execBody(s.elseBody, sc, out)
	case *forStmt:
		rc.execFor(s, sc, out)
	case *setStmt:
		sc.set(s.name, rc.eval(s.x, sc))
	case *macroDef:
		sc.set(s.name, &macroVal{def: s, scope: sc, rc: rc})
	case *includeStmt:
		name := rc.templateName(rc.eval(s.x, sc))
		rc.e.renderTemplate(rc.e.load(name), sc, out)
	case *extendsStmt:
		fail(SyntaxError, "misplaced extends")
	case *blockDef:
		rc.renderBlock(s.name, 0, s, out)
	}
}

// renderBlock renders entry k of the chain of block name in a fresh block
// scope below the template scope.
func (rc *renderCtx) renderBlock(name string, k int, fallback *blockDef, out *strings.Builder) {
	b := fallback
	if chain := rc.chains[name]; k < len(chain) {
		b = chain[k]
	}
	bs := newScope(rc.tscope)
	bs.set("super", &superRef{rc: rc, name: name, index: k})
	rc.execBody(b.body, bs, out)
}

func (rc *renderCtx) test(x expr, sc *scope) bool {
	v := rc.eval(x, sc)
	if IsUndefined(v) {
		fail(UndefinedError, "truth value of an undefined value")
	}
	return truthy(v)
}

func (rc *renderCtx) execFor(s *forStmt, sc *scope, out *strings.Builder) {
	v := rc.eval(s.iter, sc)
	var seq List
	if l, ok := v.(List); ok {
		seq = l
	} else {
		seq = sequence(v)
	}
	if len(seq) == 0 {
		rc.execBody(s.elseBody, sc, out)
		return
	}
	loop := &loopRec{length: len(seq)}
	var is *scope
	for i, item := range seq {
		loop.index = i
		if is == nil || !s.reuse {
			is = &scope{parent: sc, names: make([]string, 2, 4), vals: make([]Value, 2, 4)}
			is.names[0], is.names[1] = s.name, "loop"
		} else {
			is.names, is.vals = is.names[:2], is.vals[:2]
		}
		is.vals[0], is.vals[1] = item, loop
		rc.execBody(s.body, is, out)
	}
}

func (rc *renderCtx) eval(x expr, sc *scope) Value {
	switch x := x.(type) {
	case *litExpr:
		return x.v
	case *nameExpr:
		if v, ok := sc.lookup(x.name); ok {
			return v
		}
		if x.name == "range" {
			return rangeFn{}
		}
		return Undefined
	case *attrExpr:
		return getItem(rc.eval(x.obj, sc), x.key)
	case *indexExpr:
		obj := rc.eval(x.obj, sc)
		return getItem(obj, rc.eval(x.idx, sc))
	case *callExpr:
		return rc.evalCall(x, sc)
	case *filterExpr:
		in := rc.eval(x.x, sc)
		var args []Value
		if len(x.args) > 0 {
			args = make([]Value, len(x.args))
			for i, a := range x.args {
				args[i] = rc.eval(a, sc)
			}
		}
		return applyFilter(x.code, in, args)
	case *definedExpr:
		return !IsUndefined(rc.eval(x.x, sc)) != x.neg
	case *negExpr:
		return negate(rc.eval(x.x, sc))
	case *notExpr:
		return !rc.test(x.x, sc)
	case *andExpr:
		l := rc.eval(x.l, sc)
		if IsUndefined(l) {
			fail(UndefinedError, "truth value of an undefined value")
		}
		if !truthy(l) {
			return l
		}
		return rc.eval(x.r, sc)
	case *orExpr:
		l := rc.eval(x.l, sc)
		if IsUndefined(l) {
			fail(UndefinedError, "truth value of an undefined value")
		}
		if truthy(l) {
			return l
		}
		return rc.eval(x.r, sc)
	case *binExpr:
		l := rc.eval(x.l, sc)
		return binary(x.op, l, rc.eval(x.r, sc))
	case *cmpExpr:
		left := rc.eval(x.first, sc)
		for i, op := range x.ops {
			right := rc.eval(x.rest[i], sc)
			if !compare(op, left, right) {
				return false
			}
			left = right
		}
		return true
	case *listExpr:
		out := make(List, len(x.elems))
		for i, e := range x.elems {
			out[i] = rc.eval(e, sc)
		}
		return out
	}
	fail(TypeError, "cannot evaluate expression")
	return nil
}

func (rc *renderCtx) evalCall(x *callExpr, sc *scope) Value {
	fn := rc.eval(x.fn, sc)
	args := make([]Value, len(x.args))
	for i, a := range x.args {
		args[i] = rc.eval(a, sc)
	}
	var kwVals []Value
	if len(x.kwVals) > 0 {
		kwVals = make([]Value, len(x.kwVals))
		for i, a := range x.kwVals {
			kwVals[i] = rc.eval(a, sc)
		}
	}
	switch f := fn.(type) {
	case undefinedType:
		fail(UndefinedError, "call of an undefined value")
	case *macroVal:
		return f.call(args, x.kwNames, kwVals)
	case rangeFn:
		return callRange(args, len(kwVals) > 0)
	case *superRef:
		if len(args) > 0 || len(kwVals) > 0 {
			fail(TypeError, "super() takes no arguments")
		}
		if f.index+1 >= len(f.rc.chains[f.name]) {
			fail(UndefinedError, "no parent block for super()")
		}
		var sb strings.Builder
		f.rc.renderBlock(f.name, f.index+1, nil, &sb)
		return sb.String()
	}
	fail(TypeError, "value is not callable")
	return nil
}

// call invokes a macro and returns its output as a string.
func (m *macroVal) call(args []Value, kwNames []string, kwVals []Value) Value {
	def := m.def
	if len(args) > len(def.params) {
		fail(TypeError, "macro %s called with too many arguments", def.name)
	}
	ms := &scope{parent: m.scope, names: make([]string, 0, len(def.params)), vals: make([]Value, 0, len(def.params))}
	bound := make([]bool, len(def.params))
	for i, a := range args {
		ms.names = append(ms.names, def.params[i].name)
		ms.vals = append(ms.vals, a)
		bound[i] = true
	}
	for i, k := range kwNames {
		found := false
		for j, p := range def.params {
			if p.name == k {
				if bound[j] {
					fail(TypeError, "macro %s got multiple values for %s", def.name, k)
				}
				bound[j] = true
				ms.names = append(ms.names, k)
				ms.vals = append(ms.vals, kwVals[i])
				found = true
				break
			}
		}
		if !found {
			fail(TypeError, "macro %s has no parameter %s", def.name, k)
		}
	}
	for j, p := range def.params {
		if bound[j] {
			continue
		}
		var v Value = Undefined
		if p.def != nil {
			v = m.rc.eval(p.def, ms)
		}
		ms.set(p.name, v)
	}
	var sb strings.Builder
	m.rc.execBody(def.body, ms, &sb)
	return sb.String()
}

func callRange(args []Value, hasKw bool) Value {
	if hasKw {
		fail(TypeError, "range() takes no keyword arguments")
	}
	if len(args) < 1 || len(args) > 3 {
		fail(TypeError, "range() takes 1 to 3 arguments")
	}
	nums := make([]int64, len(args))
	for i, a := range args {
		if IsUndefined(a) {
			fail(UndefinedError, "undefined argument to range()")
		}
		if !isIntLike(a) {
			fail(TypeError, "range() arguments must be integers")
		}
		nums[i] = toInt64(a)
	}
	start, stop, step := int64(0), nums[0], int64(1)
	if len(nums) >= 2 {
		start, stop = nums[0], nums[1]
	}
	if len(nums) == 3 {
		step = nums[2]
	}
	if step == 0 {
		fail(TypeError, "range() step must not be zero")
	}
	var out List
	if step > 0 {
		for i := start; i < stop; i += step {
			out = append(out, i)
		}
	} else {
		for i := start; i > stop; i += step {
			out = append(out, i)
		}
	}
	if out == nil {
		out = List{}
	}
	return out
}
