package template

// output is the append buffer a render writes to. While quiet is set (in a
// child template after its extends tag) text, prints, includes and block
// tags produce nothing.
type output struct {
	b     []byte
	quiet bool
}

// interp holds the state shared by every rendering of one Render call.
type interp struct {
	eng *Engine
}

// rendering is the state of one template rendering: the main template or one
// include. It owns the block chains and the template scope.
type rendering struct {
	in     *interp
	tscope *scope
	chains map[string][]*blockDef
	next   *Template // parent set by an executed extends tag
}

func newRendering(in *interp, parent *scope) *rendering {
	return &rendering{in: in, tscope: newScope(parent), chains: map[string][]*blockDef{}}
}

func (r *rendering) addBlocks(t *Template) {
	for _, b := range t.blocks {
		r.chains[b.name] = append(r.chains[b.name], b)
	}
}

// run executes t (and, through extends, its ancestors) into out.
func (r *rendering) run(t *Template, out *output) {
	r.addBlocks(t)
	for cur := t; cur != nil; cur = r.next {
		r.next = nil
		execBody(cur.body, r, r.tscope, out)
		out.quiet = false
	}
}

func execBody(body []Stmt, r *rendering, sc *scope, out *output) {
	for _, s := range body {
		s.exec(r, sc, out)
	}
}

// renderBlock renders entry k of the chain of the named block.
func (r *rendering) renderBlock(name string, k int, out *output) {
	chain := r.chains[name]
	bs := &scope{parent: r.tscope, names: []string{"super"}, vals: []Value{&superFn{r: r, name: name, k: k}}}
	execBody(chain[k].body, r, bs, out)
}

// superFn is the value bound to "super" inside a block body.
type superFn struct {
	r    *rendering
	name string
	k    int
}

func (f *superFn) call() Value {
	if f.k+1 >= len(f.r.chains[f.name]) {
		throw(ErrUndefined, "no super block for %q", f.name)
	}
	out := &output{}
	f.r.renderBlock(f.name, f.k+1, out)
	return string(out.b)
}

// macroValue is a macro closed over its defining scope.
type macroValue struct {
	def   *macroDef
	scope *scope
	r     *rendering
}

func (m *macroValue) call(args []Value, kwNames []string, kwVals []Value) Value {
	def := m.def
	n := len(def.params)
	if len(args) > n {
		throw(ErrType, "macro %q called with too many arguments", def.name)
	}
	vals := make([]Value, n)
	copy(vals, args)
	for i := len(args); i < n; i++ {
		vals[i] = unbound
	}
	for j, kn := range kwNames {
		idx := -1
		for i, p := range def.params {
			if p == kn {
				idx = i
				break
			}
		}
		if idx < 0 || vals[idx] != unbound {
			throw(ErrType, "macro %q: bad keyword argument %q", def.name, kn)
		}
		vals[idx] = kwVals[j]
	}
	// Capacity is clamped so that later bindings never write into the
	// shared parameter-name array.
	ms := &scope{parent: m.scope, names: def.params[:n:n], vals: vals}
	for i := range vals {
		if vals[i] == unbound {
			if d := def.defaults[i]; d != nil {
				vals[i] = d.eval(m.r, ms)
			} else {
				vals[i] = Undefined
			}
		}
	}
	out := &output{}
	execBody(def.body, m.r, ms, out)
	return string(out.b)
}

func (s *textStmt) exec(r *rendering, sc *scope, out *output) {
	if !out.quiet {
		out.b = append(out.b, s.s...)
	}
}

func (s *printStmt) exec(r *rendering, sc *scope, out *output) {
	if out.quiet {
		return
	}
	out.b = appendValue(out.b, s.x.eval(r, sc), false)
}

func (s *ifStmt) exec(r *rendering, sc *scope, out *output) {
	for i, c := range s.conds {
		if truthy(c.eval(r, sc)) {
			execBody(s.bodies[i], r, sc, out)
			return
		}
	}
	execBody(s.elseBody, r, sc, out)
}

func (s *forStmt) exec(r *rendering, sc *scope, out *output) {
	items := seqView(s.iter.eval(r, sc))
	if len(items) == 0 {
		execBody(s.elseBody, r, sc, out)
		return
	}
	// One scope is reused for every iteration: nothing in a loop body can
	// capture it (macros and blocks never occur inside loops).
	lp := &loopRec{length: len(items)}
	ls := &scope{parent: sc, names: []string{s.name, "loop"}, vals: []Value{nil, lp}}
	for i, it := range items {
		lp.index0 = i
		ls.names = ls.names[:2]
		ls.vals = ls.vals[:2]
		ls.vals[0] = it
		execBody(s.body, r, ls, out)
	}
}

func (s *setStmt) exec(r *rendering, sc *scope, out *output) {
	sc.set(s.name, s.x.eval(r, sc))
}

func (s *macroStmt) exec(r *rendering, sc *scope, out *output) {
	sc.set(s.def.name, &macroValue{def: s.def, scope: sc, r: r})
}

// templateName evaluates the name expression of include/extends.
func templateName(x Expr, r *rendering, sc *scope) string {
	switch v := x.eval(r, sc).(type) {
	case string:
		return v
	case undefinedType:
		throw(ErrUndefined, "undefined template name")
	}
	throw(ErrType, "template name must be a string")
	return ""
}

func (s *includeStmt) exec(r *rendering, sc *scope, out *output) {
	if out.quiet {
		return
	}
	t := r.in.eng.mustLoad(templateName(s.x, r, sc))
	newRendering(r.in, sc).run(t, out)
}

func (s *extendsStmt) exec(r *rendering, sc *scope, out *output) {
	t := r.in.eng.mustLoad(templateName(s.x, r, sc))
	r.addBlocks(t)
	r.next = t
	out.quiet = true
}

func (s *blockStmt) exec(r *rendering, sc *scope, out *output) {
	if out.quiet {
		return
	}
	r.renderBlock(s.def.name, 0, out)
}
