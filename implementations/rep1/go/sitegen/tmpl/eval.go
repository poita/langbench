package tmpl

import "unicode/utf8"

type opcode uint8

const (
	opEq opcode = iota + 1
	opNe
	opLt
	opLe
	opGt
	opGe
	opIn
	opNotIn
	opAdd
	opSub
	opConcat
	opMul
	opDiv
	opFloorDiv
	opMod
	opPow
)

// An expr is an expression node; eval panics with an *Error on failure.
type expr interface {
	eval(r *rendering, sc *scope) Value
}

// A stmt is a statement node.
type stmt interface {
	exec(r *rendering, sc *scope, out *outbuf)
}

// outbuf is an output buffer. When skip is set, the template's own text and
// printed values are discarded (the part of a child template after extends).
type outbuf struct {
	b    []byte
	skip bool
}

type binding struct {
	name string
	val  Value
}

// scope maps names to values and chains to its parent. Small scopes use a
// slice with linear search; a scope built from a map (the root scope) or
// grown beyond 8 bindings uses the map.
type scope struct {
	parent *scope
	vars   []binding
	m      map[string]Value
	buf    [2]binding
}

func newScope(parent *scope) *scope {
	s := &scope{parent: parent}
	s.vars = s.buf[:0]
	return s
}

func (s *scope) set(name string, v Value) {
	if s.m != nil {
		s.m[name] = v
		return
	}
	for i := range s.vars {
		if s.vars[i].name == name {
			s.vars[i].val = v
			return
		}
	}
	s.vars = append(s.vars, binding{name, v})
	if len(s.vars) > 8 {
		s.m = make(map[string]Value, 16)
		for _, b := range s.vars {
			s.m[b.name] = b.val
		}
		s.vars = nil
	}
}

func (s *scope) lookup(name string) (Value, bool) {
	for sc := s; sc != nil; sc = sc.parent {
		if sc.m != nil {
			if v, ok := sc.m[name]; ok {
				return v, true
			}
			continue
		}
		for i := len(sc.vars) - 1; i >= 0; i-- {
			if sc.vars[i].name == name {
				return sc.vars[i].val, true
			}
		}
	}
	return nil, false
}

// rendering is the state of one rendering of a template: the main template
// or one include. It holds the block chains and the template scope.
type rendering struct {
	set     *Set
	chains  map[string][]*blockStmt
	tscope  *scope
	pending *template // parent set by an executed extends tag
}

func execAll(body []stmt, r *rendering, sc *scope, out *outbuf) {
	for _, s := range body {
		s.exec(r, sc, out)
	}
}

// runTemplate renders t in a new rendering whose template scope has the
// given parent, appending to out.
func (s *Set) runTemplate(t *template, parent *scope, out *outbuf) {
	r := &rendering{set: s, chains: make(map[string][]*blockStmt, len(t.blocks)), tscope: newScope(parent)}
	for name, b := range t.blocks {
		r.chains[name] = append(r.chains[name], b)
	}
	for cur := t; cur != nil; {
		r.pending = nil
		execAll(cur.body, r, r.tscope, out)
		cur = r.pending
		out.skip = false
	}
}

// renderBlock renders entry index of the chain of the named block.
func (r *rendering) renderBlock(name string, index int, out *outbuf) {
	b := r.chains[name][index]
	sc := newScope(r.tscope)
	sc.set("super", &superVal{r: r, name: name, index: index})
	execAll(b.body, r, sc, out)
}

// Statements.

type textStmt struct{ text string }

func (s *textStmt) exec(r *rendering, sc *scope, out *outbuf) {
	if !out.skip {
		out.b = append(out.b, s.text...)
	}
}

type printStmt struct{ e expr }

func (s *printStmt) exec(r *rendering, sc *scope, out *outbuf) {
	if out.skip {
		return
	}
	switch v := s.e.eval(r, sc).(type) {
	case string:
		out.b = append(out.b, v...)
	default:
		out.b = append(out.b, toString(v)...)
	}
}

type ifStmt struct {
	conds    []expr
	bodies   [][]stmt
	elseBody []stmt
}

func (s *ifStmt) exec(r *rendering, sc *scope, out *outbuf) {
	for i, c := range s.conds {
		if truthy(c.eval(r, sc)) {
			execAll(s.bodies[i], r, sc, out)
			return
		}
	}
	execAll(s.elseBody, r, sc, out)
}

type forStmt struct {
	name     string
	iter     expr
	body     []stmt
	elseBody []stmt
}

func (s *forStmt) exec(r *rendering, sc *scope, out *outbuf) {
	items := sequence(s.iter.eval(r, sc))
	if len(items) == 0 {
		execAll(s.elseBody, r, sc, out)
		return
	}
	li := &loopInfo{length: len(items)}
	for i, it := range items {
		li.index0 = i
		inner := newScope(sc)
		inner.vars = append(inner.vars, binding{s.name, it}, binding{"loop", li})
		execAll(s.body, r, inner, out)
	}
}

type setStmt struct {
	name string
	e    expr
}

func (s *setStmt) exec(r *rendering, sc *scope, out *outbuf) {
	sc.set(s.name, s.e.eval(r, sc))
}

type macroParam struct {
	name string
	def  expr
}

type macroStmt struct {
	name   string
	params []macroParam
	body   []stmt
}

func (s *macroStmt) exec(r *rendering, sc *scope, out *outbuf) {
	sc.set(s.name, &macroVal{def: s, sc: sc, r: r})
}

type includeStmt struct{ e expr }

func (s *includeStmt) exec(r *rendering, sc *scope, out *outbuf) {
	if out.skip {
		return
	}
	name := templateName(s.e.eval(r, sc))
	r.set.runTemplate(r.set.load(name), sc, out)
}

type extendsStmt struct{ e expr }

func (s *extendsStmt) exec(r *rendering, sc *scope, out *outbuf) {
	name := templateName(s.e.eval(r, sc))
	t := r.set.load(name)
	for n, b := range t.blocks {
		r.chains[n] = append(r.chains[n], b)
	}
	r.pending = t
	out.skip = true
}

func templateName(v Value) string {
	if isUndef(v) {
		throw(KindUndefined, "template name is undefined")
	}
	name, ok := v.(string)
	if !ok {
		throw(KindType, "template name must be a string")
	}
	return name
}

type blockStmt struct {
	name string
	body []stmt
}

func (s *blockStmt) exec(r *rendering, sc *scope, out *outbuf) {
	if out.skip {
		return
	}
	r.renderBlock(s.name, 0, out)
}

// Expressions.

type litExpr struct{ v Value }

func (e *litExpr) eval(*rendering, *scope) Value { return e.v }

type nameExpr struct{ name string }

func (e *nameExpr) eval(r *rendering, sc *scope) Value {
	if v, ok := sc.lookup(e.name); ok {
		return v
	}
	if e.name == "range" {
		return rangeFn{}
	}
	return Undefined
}

type listExpr struct{ elems []expr }

func (e *listExpr) eval(r *rendering, sc *scope) Value {
	l := make([]Value, len(e.elems))
	for i, x := range e.elems {
		l[i] = x.eval(r, sc)
	}
	return l
}

type negExpr struct{ x expr }

func (e *negExpr) eval(r *rendering, sc *scope) Value {
	v := e.x.eval(r, sc)
	checkDefined(v)
	i, f, k := toNum(v)
	switch k {
	case numInt:
		return -i
	case numFloat:
		return -f
	}
	throw(KindType, "bad operand type for unary -")
	return nil
}

type notExpr struct{ x expr }

func (e *notExpr) eval(r *rendering, sc *scope) Value { return !truthy(e.x.eval(r, sc)) }

type boolExpr struct {
	and  bool
	l, r expr
}

func (e *boolExpr) eval(r *rendering, sc *scope) Value {
	l := e.l.eval(r, sc)
	if truthy(l) == e.and {
		return e.r.eval(r, sc)
	}
	return l
}

type binaryExpr struct {
	op   opcode
	l, r expr
}

func (e *binaryExpr) eval(r *rendering, sc *scope) Value {
	l := e.l.eval(r, sc)
	rv := e.r.eval(r, sc)
	checkDefined(l)
	checkDefined(rv)
	return binaryOp(e.op, l, rv)
}

type compareExpr struct {
	first expr
	ops   []opcode
	rest  []expr
}

func (e *compareExpr) eval(r *rendering, sc *scope) Value {
	a := e.first.eval(r, sc)
	for i, op := range e.ops {
		b := e.rest[i].eval(r, sc)
		checkDefined(a)
		checkDefined(b)
		if !compareOp(op, a, b) {
			return false
		}
		a = b
	}
	return true
}

type definedExpr struct {
	x      expr
	negate bool
}

func (e *definedExpr) eval(r *rendering, sc *scope) Value {
	return isUndef(e.x.eval(r, sc)) == e.negate
}

type attrExpr struct {
	x    expr
	name string
}

func (e *attrExpr) eval(r *rendering, sc *scope) Value {
	x := e.x.eval(r, sc)
	checkDefined(x)
	return getItem(x, e.name)
}

type indexExpr struct{ x, key expr }

func (e *indexExpr) eval(r *rendering, sc *scope) Value {
	x := e.x.eval(r, sc)
	k := e.key.eval(r, sc)
	checkDefined(x)
	checkDefined(k)
	return getItem(x, k)
}

type filterExpr struct {
	x    expr
	name string
	def  *filterDef
	args []expr
}

func (e *filterExpr) eval(r *rendering, sc *scope) Value {
	x := e.x.eval(r, sc)
	var args []Value
	if len(e.args) > 0 {
		args = make([]Value, len(e.args))
		for i, a := range e.args {
			args[i] = a.eval(r, sc)
		}
	}
	if !e.def.allowUndefined {
		checkDefined(x)
	}
	if len(args) < e.def.minArgs || len(args) > e.def.maxArgs {
		throw(KindType, "wrong number of arguments to filter %s", e.name)
	}
	return e.def.fn(x, args)
}

type callExpr struct {
	fn      expr
	args    []expr
	kwNames []string
	kwArgs  []expr
}

func (e *callExpr) eval(r *rendering, sc *scope) Value {
	f := e.fn.eval(r, sc)
	args := make([]Value, len(e.args))
	for i, a := range e.args {
		args[i] = a.eval(r, sc)
	}
	var kw []Value
	if len(e.kwArgs) > 0 {
		kw = make([]Value, len(e.kwArgs))
		for i, a := range e.kwArgs {
			kw[i] = a.eval(r, sc)
		}
	}
	switch f := f.(type) {
	case *macroVal:
		return callMacro(f, args, e.kwNames, kw)
	case rangeFn:
		return callRange(args, kw)
	case *superVal:
		if len(args) > 0 || len(kw) > 0 {
			throw(KindType, "super() takes no arguments")
		}
		if f.index+1 >= len(f.r.chains[f.name]) {
			throw(KindUndefined, "no parent block for super()")
		}
		out := &outbuf{}
		f.r.renderBlock(f.name, f.index+1, out)
		return string(out.b)
	case undefinedType:
		throw(KindUndefined, "call of an undefined value")
	}
	throw(KindType, "value is not callable")
	return nil
}

func callMacro(m *macroVal, args []Value, kwNames []string, kw []Value) Value {
	def := m.def
	if len(args) > len(def.params) {
		throw(KindType, "too many arguments to macro %s", def.name)
	}
	sc := newScope(m.sc)
	bound := make([]bool, len(def.params))
	vals := make([]Value, len(def.params))
	for i, a := range args {
		bound[i] = true
		vals[i] = a
	}
	for i, name := range kwNames {
		idx := -1
		for j, p := range def.params {
			if p.name == name {
				idx = j
				break
			}
		}
		if idx < 0 || bound[idx] {
			throw(KindType, "bad keyword argument %q to macro %s", name, def.name)
		}
		bound[idx] = true
		vals[idx] = kw[i]
	}
	for i, p := range def.params {
		if bound[i] {
			sc.set(p.name, vals[i])
		}
	}
	for i, p := range def.params {
		switch {
		case bound[i]:
		case p.def != nil:
			sc.set(p.name, p.def.eval(m.r, sc))
		default:
			sc.set(p.name, Undefined)
		}
	}
	out := &outbuf{}
	execAll(def.body, m.r, sc, out)
	return string(out.b)
}

func callRange(args, kw []Value) Value {
	if len(kw) > 0 {
		throw(KindType, "range() takes no keyword arguments")
	}
	if len(args) < 1 || len(args) > 3 {
		throw(KindType, "range() takes 1 to 3 arguments")
	}
	n := make([]int64, len(args))
	for i, a := range args {
		checkDefined(a)
		switch x := a.(type) {
		case int64:
			n[i] = x
		case bool:
			n[i] = b2i(x)
		default:
			throw(KindType, "range() arguments must be integers")
		}
	}
	start, stop, step := int64(0), n[0], int64(1)
	if len(n) >= 2 {
		start, stop = n[0], n[1]
	}
	if len(n) == 3 {
		step = n[2]
	}
	if step == 0 {
		throw(KindType, "range() step must not be zero")
	}
	var out []Value
	if step > 0 && start < stop {
		out = make([]Value, 0, (stop-start+step-1)/step)
	} else if step < 0 && start > stop {
		out = make([]Value, 0, (start-stop-step-1)/(-step))
	}
	for i := start; (step > 0 && i < stop) || (step < 0 && i > stop); i += step {
		out = append(out, i)
	}
	if out == nil {
		out = []Value{}
	}
	return out
}

func b2i(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

func isUndef(v Value) bool {
	_, ok := v.(undefinedType)
	return ok
}

func checkDefined(v Value) {
	if _, ok := v.(undefinedType); ok {
		throw(KindUndefined, "use of an undefined value")
	}
}

// truthy reports the truthiness of v; the undefined value is an error.
func truthy(v Value) bool {
	switch x := v.(type) {
	case bool:
		return x
	case noneType:
		return false
	case int64:
		return x != 0
	case float64:
		return x != 0
	case string:
		return x != ""
	case []Value:
		return len(x) != 0
	case *Dict:
		return x.Len() != 0
	case undefinedType:
		throw(KindUndefined, "truth value of an undefined value")
	}
	return true
}

// sequence returns the sequence view of v.
func sequence(v Value) []Value {
	switch x := v.(type) {
	case []Value:
		return x
	case *Dict:
		out := make([]Value, len(x.keys))
		for i, k := range x.keys {
			out[i] = k
		}
		return out
	case string:
		out := make([]Value, 0, len(x))
		for i := 0; i < len(x); {
			n := runeLen(x[i:])
			out = append(out, x[i:i+n])
			i += n
		}
		return out
	case undefinedType:
		throw(KindUndefined, "iteration over an undefined value")
	}
	throw(KindType, "value is not iterable")
	return nil
}

// runeLen returns the byte length of the first code point of s.
func runeLen(s string) int {
	_, n := utf8.DecodeRuneInString(s)
	return n
}

// getItem implements attribute and subscript access.
func getItem(a, k Value) Value {
	switch x := a.(type) {
	case *Dict:
		if ks, ok := k.(string); ok {
			if v, ok := x.m[ks]; ok {
				return v
			}
		}
	case []Value:
		if i, ok := intKey(k); ok {
			if i < 0 {
				i += int64(len(x))
			}
			if i >= 0 && i < int64(len(x)) {
				return x[i]
			}
		}
	case string:
		if i, ok := intKey(k); ok {
			return stringIndex(x, i)
		}
	case *loopInfo:
		if ks, ok := k.(string); ok {
			switch ks {
			case "index":
				return int64(x.index0 + 1)
			case "index0":
				return int64(x.index0)
			case "first":
				return x.index0 == 0
			case "last":
				return x.index0 == x.length-1
			case "length":
				return int64(x.length)
			}
		}
	}
	return Undefined
}

func intKey(k Value) (int64, bool) {
	switch x := k.(type) {
	case int64:
		return x, true
	case bool:
		return b2i(x), true
	}
	return 0, false
}

func stringIndex(s string, i int64) Value {
	if i < 0 {
		n := int64(0)
		for range s {
			n++
		}
		i += n
		if i < 0 {
			return Undefined
		}
	}
	var n int64
	for pos := range s {
		if n == i {
			return s[pos : pos+runeLen(s[pos:])]
		}
		n++
	}
	return Undefined
}
