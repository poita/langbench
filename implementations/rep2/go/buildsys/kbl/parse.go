package kbl

import (
	"strings"

	"kiln/errs"
)

var reserved = map[string]bool{
	"abort": true, "after": true, "cmd": true, "cost": true, "default": true,
	"depfile": true, "each": true, "elsewhen": true, "false": true, "in": true,
	"include": true, "let": true, "otherwise": true, "out": true, "phony": true,
	"rule": true, "set": true, "step": true, "true": true, "use": true, "when": true,
}

// IsReserved reports whether name is a KBL reserved word.
func IsReserved(name string) bool { return reserved[name] }

// syntaxError is the panic value used internally to abandon the current
// logical line.
type syntaxError struct{}

func fail() { panic(syntaxError{}) }

type parser struct {
	toks []token
	pos  int
}

func (p *parser) peek() (token, bool) {
	if p.pos < len(p.toks) {
		return p.toks[p.pos], true
	}
	return token{}, false
}

func (p *parser) atOp(op string) bool {
	t, ok := p.peek()
	return ok && t.is(op)
}

func (p *parser) next() token {
	if p.pos >= len(p.toks) {
		fail()
	}
	t := p.toks[p.pos]
	p.pos++
	return t
}

func (p *parser) expectOp(op string) {
	if !p.atOp(op) {
		fail()
	}
	p.pos++
}

func (p *parser) done() bool { return p.pos >= len(p.toks) }

// ident consumes an identifier; reserved words are rejected unless anyName.
func (p *parser) ident(anyName bool) string {
	t := p.next()
	if t.kind != tIdent || (!anyName && reserved[t.text]) {
		fail()
	}
	return t.text
}

// ---- expressions ----

func (p *parser) expr() Expr { return p.pipe() }

func (p *parser) pipe() Expr {
	l := p.binaryLevel(0)
	for p.atOp("|>") {
		p.pos++
		name := p.ident(true)
		args := []Expr{l}
		if p.atOp("(") {
			p.pos++
			args = append(args, p.exprList(")")...)
		}
		l = newCall(name, args)
	}
	return l
}

// binary operator levels, lowest first (after the pipe level).
var levels = [][]string{
	{"||"},
	{"&&"},
	{"==", "!=", "<", "<=", ">", ">="},
	{"++"},
	{"~"},
	{"+", "-"},
	{"*", "/", "%"},
}

func (p *parser) binaryLevel(lv int) Expr {
	if lv == len(levels) {
		return p.unary()
	}
	l := p.binaryLevel(lv + 1)
	for {
		t, ok := p.peek()
		if !ok || t.kind != tOp {
			return l
		}
		match := false
		for _, op := range levels[lv] {
			if t.text == op {
				match = true
				break
			}
		}
		if !match {
			return l
		}
		p.pos++
		r := p.binaryLevel(lv + 1)
		l = &binary{op: t.text, l: l, r: r}
	}
}

func (p *parser) unary() Expr {
	if t, ok := p.peek(); ok && (t.is("!") || t.is("-")) {
		p.pos++
		return &unary{op: t.text, x: p.unary()}
	}
	return p.postfix()
}

func (p *parser) postfix() Expr {
	x := p.primary()
	for {
		switch {
		case p.atOp("["):
			p.pos++
			i := p.expr()
			p.expectOp("]")
			x = &index{x: x, i: i}
		case p.atOp("("):
			fail() // a call is only legal directly on an identifier
		default:
			return x
		}
	}
}

// exprList parses expr {"," expr} [","] up to and including the closer.
func (p *parser) exprList(closer string) []Expr {
	var out []Expr
	for !p.atOp(closer) {
		out = append(out, p.expr())
		if p.atOp(",") {
			p.pos++
			continue
		}
		break
	}
	p.expectOp(closer)
	return out
}

func (p *parser) primary() Expr {
	t := p.next()
	switch t.kind {
	case tInt:
		return &intLit{v: t.num}
	case tStr:
		return parseStringLit(t.text)
	case tIdent:
		if p.atOp("(") {
			p.pos++
			return newCall(t.text, p.exprList(")"))
		}
		switch t.text {
		case "true":
			return &boolLit{v: true}
		case "false":
			return &boolLit{v: false}
		}
		if reserved[t.text] {
			fail()
		}
		return &varRef{name: t.text}
	case tOp:
		switch t.text {
		case "(":
			x := p.expr()
			p.expectOp(")")
			return x
		case "[":
			return &listLit{elems: p.exprList("]")}
		}
	}
	fail()
	return nil
}

func newCall(name string, args []Expr) *call {
	return &call{name: name, fn: builtins[name], args: args}
}

// ---- string literals ----

// parseStringLit parses a raw literal token (quotes included).
func parseStringLit(raw string) Expr {
	if raw[0] == '\'' {
		body := raw[1 : len(raw)-1]
		return &strLit{parts: []strPart{{lit: strings.ReplaceAll(body, "''", "'")}}}
	}
	s := raw[1 : len(raw)-1]
	var parts []strPart
	var lit strings.Builder
	flush := func() {
		if lit.Len() > 0 {
			parts = append(parts, strPart{lit: lit.String()})
			lit.Reset()
		}
	}
	for i := 0; i < len(s); {
		c := s[i]
		switch c {
		case '\\':
			if i+1 >= len(s) {
				fail()
			}
			switch s[i+1] {
			case '\\', '"':
				lit.WriteByte(s[i+1])
			case 'n':
				lit.WriteByte('\n')
			case 't':
				lit.WriteByte('\t')
			case 'r':
				lit.WriteByte('\r')
			case '0':
				lit.WriteByte(0)
			default:
				fail()
			}
			i += 2
		case '{':
			if i+1 < len(s) && s[i+1] == '{' {
				lit.WriteByte('{')
				i += 2
				continue
			}
			end := skipInterp(s, i+1)
			if end < 0 {
				fail()
			}
			body := s[i+1 : end-1]
			toks, ok := tokenize(body)
			if !ok || len(toks) == 0 {
				fail()
			}
			sub := &parser{toks: toks}
			x := sub.expr()
			if !sub.done() {
				fail()
			}
			flush()
			parts = append(parts, strPart{expr: x})
			i = end
		case '}':
			if i+1 < len(s) && s[i+1] == '}' {
				lit.WriteByte('}')
				i += 2
				continue
			}
			fail()
		default:
			lit.WriteByte(c)
			i++
		}
	}
	flush()
	return &strLit{parts: parts}
}

// ---- statements ----

type blockKind uint8

const (
	bWhen blockKind = iota
	bEach
	bRule
	bStep
)

type frame struct {
	kind   blockKind
	header int // line number of the (latest) header line
	stmts  []Stmt

	// when
	when      *whenStmt
	otherwise bool
	// each
	each *eachStmt
	// rule
	rule *ruleStmt
	// step
	fields []stepField
}

// Parse lexes and parses a whole build file. name is the workspace path used
// in E_PARSE details.
func Parse(name, src string) (*File, *errs.Error) {
	lines, errLine, ok := lexFile(src)
	if !ok {
		return nil, parseErr(name, errLine)
	}
	root := &frame{kind: bWhen}
	stack := []*frame{root}
	for _, ll := range lines {
		if !parseLine(&stack, ll) {
			return nil, parseErr(name, ll.line)
		}
	}
	if len(stack) > 1 {
		return nil, parseErr(name, stack[len(stack)-1].header)
	}
	return &File{Name: name, Stmts: root.stmts}, nil
}

func parseLine(stack *[]*frame, ll logicalLine) (ok bool) {
	defer func() {
		if r := recover(); r != nil {
			if _, is := r.(syntaxError); !is {
				panic(r)
			}
			ok = false
		}
	}()
	toks := ll.toks
	top := (*stack)[len(*stack)-1]
	switch {
	case toks[0].is("}"):
		terminator(stack, top, ll)
	case toks[len(toks)-1].is("{"):
		if top.kind == bStep {
			fail()
		}
		header(stack, ll)
	case top.kind == bStep:
		top.fields = append(top.fields, stepFieldLine(toks))
	default:
		top.stmts = append(top.stmts, simpleStmt(toks))
	}
	return true
}

func terminator(stack *[]*frame, top *frame, ll logicalLine) {
	toks := ll.toks
	if len(*stack) == 1 {
		fail()
	}
	if len(toks) == 1 {
		closeFrame(stack, top)
		return
	}
	if top.kind != bWhen || top.otherwise {
		fail()
	}
	if toks[1].kind == tIdent && toks[1].text == "elsewhen" && len(toks) >= 4 && toks[len(toks)-1].is("{") {
		p := &parser{toks: toks[2 : len(toks)-1]}
		cond := p.expr()
		if !p.done() {
			fail()
		}
		top.when.bodies = append(top.when.bodies, top.stmts)
		top.when.conds = append(top.when.conds, cond)
		top.stmts = nil
		top.header = ll.line
		return
	}
	if toks[1].kind == tIdent && toks[1].text == "otherwise" && len(toks) == 3 && toks[2].is("{") {
		top.when.bodies = append(top.when.bodies, top.stmts)
		top.stmts = nil
		top.otherwise = true
		top.header = ll.line
		return
	}
	fail()
}

func closeFrame(stack *[]*frame, top *frame) {
	var st Stmt
	switch top.kind {
	case bWhen:
		if top.otherwise {
			top.when.otherwise = top.stmts
		} else {
			top.when.bodies = append(top.when.bodies, top.stmts)
		}
		st = top.when
	case bEach:
		top.each.body = top.stmts
		st = top.each
	case bRule:
		top.rule.body = top.stmts
		st = top.rule
	case bStep:
		st = &stepStmt{fields: top.fields}
	}
	*stack = (*stack)[:len(*stack)-1]
	parent := (*stack)[len(*stack)-1]
	parent.stmts = append(parent.stmts, st)
}

func header(stack *[]*frame, ll logicalLine) {
	toks := ll.toks[:len(ll.toks)-1]
	if len(toks) == 0 || toks[0].kind != tIdent {
		fail()
	}
	p := &parser{toks: toks, pos: 1}
	f := &frame{header: ll.line}
	switch toks[0].text {
	case "step":
		if len(toks) != 1 {
			fail()
		}
		f.kind = bStep
	case "when":
		f.kind = bWhen
		cond := p.expr()
		if !p.done() {
			fail()
		}
		f.when = &whenStmt{conds: []Expr{cond}}
	case "each":
		f.kind = bEach
		e := &eachStmt{}
		e.name = p.ident(false)
		if p.atOp(",") {
			p.pos++
			e.index = e.name
			e.name = p.ident(false)
			if e.index == e.name {
				fail()
			}
		}
		if t := p.next(); t.kind != tIdent || t.text != "in" {
			fail()
		}
		e.x = p.expr()
		if !p.done() {
			fail()
		}
		f.each = e
	case "rule":
		f.kind = bRule
		r := &ruleStmt{name: p.ident(false)}
		p.expectOp("(")
		seen := map[string]bool{}
		sawDefault := false
		for !p.atOp(")") {
			pm := param{name: p.ident(false)}
			if seen[pm.name] {
				fail()
			}
			seen[pm.name] = true
			if p.atOp("=") {
				p.pos++
				pm.def = p.expr()
				sawDefault = true
			} else if sawDefault {
				fail()
			}
			r.params = append(r.params, pm)
			if p.atOp(",") {
				p.pos++
				continue
			}
			break
		}
		p.expectOp(")")
		if !p.done() {
			fail()
		}
		f.rule = r
	default:
		fail()
	}
	*stack = append(*stack, f)
}

func stepFieldLine(toks []token) stepField {
	if toks[0].kind != tIdent {
		fail()
	}
	p := &parser{toks: toks, pos: 1}
	var f stepField
	switch toks[0].text {
	case "out":
		f.kind = fOut
	case "in":
		f.kind = fIn
	case "after":
		f.kind = fAfter
	case "cost":
		f.kind = fCost
	case "depfile":
		f.kind = fDepfile
	case "cmd":
		f.kind = fCmd
		f.cmdName = p.ident(true)
		p.expectOp("(")
		f.args = p.exprList(")")
		if !p.done() {
			fail()
		}
		return f
	default:
		fail()
	}
	f.x = p.expr()
	if !p.done() {
		fail()
	}
	return f
}

func simpleStmt(toks []token) Stmt {
	if toks[0].kind != tIdent {
		fail()
	}
	p := &parser{toks: toks, pos: 1}
	var st Stmt
	switch toks[0].text {
	case "let":
		name := p.ident(false)
		p.expectOp("=")
		st = &letStmt{name: name, x: p.expr()}
	case "set":
		name := p.ident(false)
		p.expectOp("=")
		st = &setStmt{name: name, x: p.expr()}
	case "phony":
		name := p.ident(false)
		p.expectOp("=")
		st = &phonyStmt{name: name, x: p.expr()}
	case "include":
		st = &includeStmt{x: p.expr()}
	case "abort":
		st = &abortStmt{x: p.expr()}
	case "default":
		st = &defaultStmt{x: p.expr()}
	case "use":
		st = p.useStmt()
	default:
		fail()
	}
	if !p.done() {
		fail()
	}
	return st
}

func (p *parser) useStmt() Stmt {
	u := &useStmt{name: p.ident(true)}
	p.expectOp("(")
	for !p.atOp(")") {
		t, _ := p.peek()
		if t.kind == tIdent && !reserved[t.text] && p.pos+1 < len(p.toks) && p.toks[p.pos+1].is("=") {
			p.pos += 2
			u.kws = append(u.kws, kwArg{name: t.text, x: p.expr()})
		} else {
			if len(u.kws) > 0 {
				fail()
			}
			u.pos = append(u.pos, p.expr())
		}
		if p.atOp(",") {
			p.pos++
			continue
		}
		break
	}
	p.expectOp(")")
	return u
}
