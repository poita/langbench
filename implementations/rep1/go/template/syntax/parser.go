package syntax

import (
	"example.com/template/value"
)

// Parse lexes and parses the template source. Every failure is a
// tplerr.Syntax error. Filter names are collected in Template.Filters but
// not checked.
func Parse(name, src string) (tpl *Template, err error) {
	items, err := lex(src)
	if err != nil {
		return nil, err
	}
	p := &parser{items: items, blocks: map[string]*Block{}}
	defer func() {
		if r := recover(); r != nil {
			if pe, ok := r.(parseError); ok {
				tpl, err = nil, pe.err
				return
			}
			panic(r)
		}
	}()
	body, term := p.parseBody(nil)
	if term != "" {
		p.fail("unexpected {%% %s %%}", term)
	}
	return &Template{Name: name, Body: body, Blocks: p.blocks, Filters: p.filters}, nil
}

// parseError carries a syntax error through panics inside the parser.
type parseError struct{ err error }

type parser struct {
	items   []item
	pos     int
	depth   int // nesting inside if/for/macro/block bodies
	extends bool
	blocks  map[string]*Block
	filters []string
}

func (p *parser) fail(format string, args ...any) {
	panic(parseError{syntaxError(format, args...)})
}

// tags is a cursor over the tokens of one tag.
type tags struct {
	p    *parser
	toks []Token
	pos  int
}

func (t *tags) peek() Token { return t.toks[t.pos] }

func (t *tags) next() Token {
	tok := t.toks[t.pos]
	if tok.Kind != TokEOF {
		t.pos++
	}
	return tok
}

func (t *tags) isOp(s string) bool {
	tok := t.peek()
	return tok.Kind == TokOp && tok.Text == s
}

func (t *tags) isName(s string) bool {
	tok := t.peek()
	return tok.Kind == TokName && tok.Text == s
}

func (t *tags) expectOp(s string) {
	if !t.isOp(s) {
		t.p.fail("expected %q", s)
	}
	t.pos++
}

func (t *tags) expectEOF() {
	if t.peek().Kind != TokEOF {
		t.p.fail("unexpected %q at end of tag", t.peek().Text)
	}
}

// ident consumes a non-keyword name.
func (t *tags) ident() string {
	tok := t.peek()
	if tok.Kind != TokName || keywords[tok.Text] {
		t.p.fail("expected a name")
	}
	t.pos++
	return tok.Text
}

// parseBody parses nodes until a statement whose keyword is in stop (which
// is consumed and returned along with its tag cursor) or, when stop is nil,
// until the end of the template.
func (p *parser) parseBody(stop map[string]bool) ([]Node, string) {
	nodes, term, _ := p.parseBodyTags(stop)
	return nodes, term
}

func (p *parser) parseBodyTags(stop map[string]bool) ([]Node, string, *tags) {
	var nodes []Node
	for p.pos < len(p.items) {
		it := p.items[p.pos]
		p.pos++
		switch it.kind {
		case itemText:
			nodes = append(nodes, &Text{Text: it.text})
		case itemPrint:
			t := &tags{p: p, toks: it.toks}
			x := t.expr()
			t.expectEOF()
			nodes = append(nodes, &Print{X: x})
		case itemStmt:
			t := &tags{p: p, toks: it.toks}
			kw := t.peek()
			if kw.Kind != TokName {
				p.fail("expected a statement keyword")
			}
			if stop[kw.Text] {
				t.next()
				return nodes, kw.Text, t
			}
			t.next()
			nodes = append(nodes, p.statement(kw.Text, t))
		}
	}
	if stop != nil {
		p.fail("unexpected end of template: unclosed block")
	}
	return nodes, "", nil
}

var (
	stopIf    = map[string]bool{"elif": true, "else": true, "endif": true}
	stopElse  = map[string]bool{"endif": true}
	stopFor   = map[string]bool{"else": true, "endfor": true}
	stopEndFr = map[string]bool{"endfor": true}
	stopMacro = map[string]bool{"endmacro": true}
	stopBlock = map[string]bool{"endblock": true}
)

func (p *parser) statement(kw string, t *tags) Node {
	switch kw {
	case "if":
		return p.parseIf(t)
	case "for":
		return p.parseFor(t)
	case "set":
		name := t.ident()
		t.expectOp("=")
		x := t.expr()
		t.expectEOF()
		return &Set{Name: name, X: x}
	case "macro":
		return p.parseMacro(t)
	case "include":
		x := t.expr()
		t.expectEOF()
		return &Include{X: x}
	case "extends":
		if p.depth > 0 || p.extends {
			p.fail("misplaced or repeated extends")
		}
		p.extends = true
		x := t.expr()
		t.expectEOF()
		return &Extends{X: x}
	case "block":
		return p.parseBlock(t)
	}
	p.fail("unknown or unexpected statement %q", kw)
	return nil
}

func (p *parser) parseIf(t *tags) Node {
	n := &If{}
	cond := t.expr()
	t.expectEOF()
	for {
		p.depth++
		body, term, tt := p.parseBodyTags(stopIf)
		p.depth--
		n.Conds = append(n.Conds, cond)
		n.Bodies = append(n.Bodies, body)
		switch term {
		case "endif":
			tt.expectEOF()
			return n
		case "else":
			tt.expectEOF()
			p.depth++
			n.Else, term, tt = p.parseBodyTags(stopElse)
			p.depth--
			if n.Else == nil {
				n.Else = []Node{}
			}
			tt.expectEOF()
			return n
		}
		cond = tt.expr()
		tt.expectEOF()
	}
}

func (p *parser) parseFor(t *tags) Node {
	n := &For{Var: t.ident()}
	if !t.isName("in") {
		p.fail("expected 'in'")
	}
	t.next()
	n.Iter = t.expr()
	t.expectEOF()
	p.depth++
	body, term, tt := p.parseBodyTags(stopFor)
	n.Body = body
	tt.expectEOF()
	if term == "else" {
		n.Else, _, tt = p.parseBodyTags(stopEndFr)
		tt.expectEOF()
	}
	p.depth--
	return n
}

func (p *parser) parseMacro(t *tags) Node {
	n := &MacroDef{Name: t.ident()}
	t.expectOp("(")
	seen := map[string]bool{}
	sawDefault := false
	if !t.isOp(")") {
		for {
			name := t.ident()
			if seen[name] {
				p.fail("duplicate macro parameter %q", name)
			}
			seen[name] = true
			prm := Param{Name: name}
			if t.isOp("=") {
				t.next()
				prm.Default = t.expr()
				sawDefault = true
			} else if sawDefault {
				p.fail("non-default parameter %q follows a default parameter", name)
			}
			n.Params = append(n.Params, prm)
			if t.isOp(",") {
				t.next()
				continue
			}
			break
		}
	}
	t.expectOp(")")
	t.expectEOF()
	p.depth++
	body, _, tt := p.parseBodyTags(stopMacro)
	p.depth--
	tt.expectEOF()
	n.Body = body
	return n
}

func (p *parser) parseBlock(t *tags) Node {
	name := t.ident()
	t.expectEOF()
	if _, dup := p.blocks[name]; dup {
		p.fail("duplicate block %q", name)
	}
	n := &Block{Name: name}
	p.blocks[name] = n
	p.depth++
	body, _, tt := p.parseBodyTags(stopBlock)
	p.depth--
	if tt.peek().Kind != TokEOF {
		if end := tt.ident(); end != name {
			p.fail("endblock %q does not match block %q", end, name)
		}
	}
	tt.expectEOF()
	n.Body = body
	return n
}

// ---- expressions ----

func (t *tags) expr() Expr { return t.or() }

func (t *tags) or() Expr {
	l := t.and()
	for t.isName("or") {
		t.next()
		l = &Logic{Or: true, L: l, R: t.and()}
	}
	return l
}

func (t *tags) and() Expr {
	l := t.not()
	for t.isName("and") {
		t.next()
		l = &Logic{L: l, R: t.not()}
	}
	return l
}

func (t *tags) not() Expr {
	if t.isName("not") {
		t.next()
		return &Not{X: t.not()}
	}
	return t.compare()
}

func (t *tags) cmpOp() (value.CmpOp, bool) {
	tok := t.peek()
	switch tok.Kind {
	case TokOp:
		var op value.CmpOp
		switch tok.Text {
		case "==":
			op = value.CmpEq
		case "!=":
			op = value.CmpNe
		case "<":
			op = value.CmpLt
		case "<=":
			op = value.CmpLe
		case ">":
			op = value.CmpGt
		case ">=":
			op = value.CmpGe
		default:
			return 0, false
		}
		t.next()
		return op, true
	case TokName:
		if tok.Text == "in" {
			t.next()
			return value.CmpIn, true
		}
		if tok.Text == "not" {
			if nx := t.toks[t.pos+1]; nx.Kind == TokName && nx.Text == "in" {
				t.pos += 2
				return value.CmpNotIn, true
			}
		}
	}
	return 0, false
}

func (t *tags) compare() Expr {
	first := t.additive()
	var ops []value.CmpOp
	var rest []Expr
	for {
		op, ok := t.cmpOp()
		if !ok {
			break
		}
		ops = append(ops, op)
		rest = append(rest, t.additive())
	}
	if ops == nil {
		return first
	}
	return &Compare{First: first, Ops: ops, Rest: rest}
}

func (t *tags) additive() Expr {
	l := t.concat()
	for {
		switch {
		case t.isOp("+"):
			t.next()
			l = &Binary{Op: value.OpAdd, L: l, R: t.concat()}
		case t.isOp("-"):
			t.next()
			l = &Binary{Op: value.OpSub, L: l, R: t.concat()}
		default:
			return l
		}
	}
}

func (t *tags) concat() Expr {
	l := t.term()
	for t.isOp("~") {
		t.next()
		l = &Binary{Op: value.OpConcat, L: l, R: t.term()}
	}
	return l
}

func (t *tags) term() Expr {
	l := t.power()
	for {
		var op value.Op
		switch {
		case t.isOp("*"):
			op = value.OpMul
		case t.isOp("/"):
			op = value.OpDiv
		case t.isOp("//"):
			op = value.OpFloorDiv
		case t.isOp("%"):
			op = value.OpMod
		default:
			return l
		}
		t.next()
		l = &Binary{Op: op, L: l, R: t.power()}
	}
}

func (t *tags) power() Expr {
	l := t.filtered()
	for t.isOp("**") {
		t.next()
		l = &Binary{Op: value.OpPow, L: l, R: t.filtered()}
	}
	return l
}

func (t *tags) filtered() Expr {
	x := t.unary()
	for {
		switch {
		case t.isOp("|"):
			t.next()
			f := &FilterExpr{X: x, Name: t.ident()}
			t.p.filters = append(t.p.filters, f.Name)
			if t.isOp("(") {
				t.next()
				f.Args = t.exprList(")")
			}
			x = f
		case t.isName("is"):
			t.next()
			neg := false
			if t.isName("not") {
				t.next()
				neg = true
			}
			if !t.isName("defined") {
				t.p.fail("unknown test after 'is'")
			}
			t.next()
			x = &IsDefined{X: x, Negate: neg}
		default:
			return x
		}
	}
}

// exprList parses comma-separated expressions up to and including the
// closing punctuation; a trailing comma is an error.
func (t *tags) exprList(closer string) []Expr {
	var out []Expr
	if t.isOp(closer) {
		t.next()
		return out
	}
	for {
		out = append(out, t.expr())
		if t.isOp(",") {
			t.next()
			continue
		}
		t.expectOp(closer)
		return out
	}
}

func (t *tags) unary() Expr {
	if t.isOp("-") {
		t.next()
		return &Neg{X: t.unary()}
	}
	return t.postfix()
}

func (t *tags) postfix() Expr {
	x := t.primary()
	for {
		switch {
		case t.isOp("."):
			t.next()
			tok := t.next()
			if tok.Kind != TokName {
				t.p.fail("expected an attribute name")
			}
			x = &Attr{X: x, Name: tok.Text}
		case t.isOp("["):
			t.next()
			key := t.expr()
			t.expectOp("]")
			x = &Index{X: x, Key: key}
		case t.isOp("("):
			t.next()
			x = t.callArgs(x)
		default:
			return x
		}
	}
}

func (t *tags) callArgs(fn Expr) Expr {
	c := &Call{Fn: fn}
	if t.isOp(")") {
		t.next()
		return c
	}
	seen := map[string]bool{}
	for {
		tok, nx := t.peek(), t.toks[t.pos+1]
		if tok.Kind == TokName && !keywords[tok.Text] && nx.Kind == TokOp && nx.Text == "=" {
			t.pos += 2
			if seen[tok.Text] {
				t.p.fail("duplicate keyword argument %q", tok.Text)
			}
			seen[tok.Text] = true
			c.Kwargs = append(c.Kwargs, Kwarg{Name: tok.Text, X: t.expr()})
		} else {
			if len(c.Kwargs) > 0 {
				t.p.fail("positional argument follows keyword argument")
			}
			c.Args = append(c.Args, t.expr())
		}
		if t.isOp(",") {
			t.next()
			continue
		}
		t.expectOp(")")
		return c
	}
}

func (t *tags) primary() Expr {
	tok := t.next()
	switch tok.Kind {
	case TokInt:
		return &Literal{Value: tok.Int}
	case TokFloat:
		return &Literal{Value: tok.Float}
	case TokString:
		return &Literal{Value: tok.Text}
	case TokName:
		switch tok.Text {
		case "true":
			return &Literal{Value: true}
		case "false":
			return &Literal{Value: false}
		case "none":
			return &Literal{Value: value.None}
		}
		if keywords[tok.Text] {
			t.p.fail("unexpected keyword %q", tok.Text)
		}
		return &Name{Name: tok.Text}
	case TokOp:
		switch tok.Text {
		case "(":
			x := t.expr()
			t.expectOp(")")
			return x
		case "[":
			return &ListLit{Elems: t.exprList("]")}
		}
	}
	t.p.fail("unexpected %q in expression", tok.Text)
	return nil
}
