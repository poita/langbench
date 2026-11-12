package tmpl

// template is a parsed template.
type template struct {
	name   string
	body   []stmt
	blocks map[string]*blockStmt // every block in the template, by name
}

var keywords = map[string]bool{
	"and": true, "or": true, "not": true, "in": true, "is": true,
	"true": true, "false": true, "none": true,
}

type parser struct {
	items []item
	pos   int

	toks []token // tokens of the current tag
	tp   int

	depth      int // nesting of if/for/macro/block bodies
	hasExtends bool
	blocks     map[string]*blockStmt
	badFilter  string
}

// parseTemplate lexes and parses src and checks its filter names. It panics
// with an *Error if the template is invalid.
func parseTemplate(name, src string) *template {
	p := &parser{items: lex(src), blocks: map[string]*blockStmt{}}
	body, term := p.parseBody()
	if term != "" {
		throw(KindSyntax, "unexpected %q tag", term)
	}
	if p.badFilter != "" {
		throw(KindFilter, "unknown filter %q", p.badFilter)
	}
	return &template{name: name, body: body, blocks: p.blocks}
}

var endKeywords = map[string]bool{
	"elif": true, "else": true, "endif": true, "endfor": true, "endmacro": true, "endblock": true,
}

// parseBody parses statements until the end of the template or until a tag
// that ends a body ("elif", "else", "endif", ...). In the second case the
// keyword is returned and the parser is positioned after it in that tag.
func (p *parser) parseBody() (body []stmt, term string) {
	for p.pos < len(p.items) {
		it := p.items[p.pos]
		p.pos++
		switch it.kind {
		case itText:
			body = append(body, &textStmt{text: it.text})
		case itVar:
			p.toks, p.tp = it.toks, 0
			if len(p.toks) == 0 {
				throw(KindSyntax, "empty expression")
			}
			e := p.parseExpr()
			p.expectEnd()
			body = append(body, &printStmt{e: e})
		case itStmt:
			p.toks, p.tp = it.toks, 0
			if len(p.toks) == 0 || p.toks[0].kind != tName {
				throw(KindSyntax, "empty or malformed statement")
			}
			kw := p.toks[0].s
			p.tp = 1
			if endKeywords[kw] {
				return body, kw
			}
			body = append(body, p.parseStatement(kw))
		}
	}
	return body, ""
}

// parseNested parses a body one level deeper.
func (p *parser) parseNested() ([]stmt, string) {
	p.depth++
	body, term := p.parseBody()
	p.depth--
	return body, term
}

func (p *parser) parseStatement(kw string) stmt {
	switch kw {
	case "if":
		return p.parseIf()
	case "for":
		return p.parseFor()
	case "set":
		name := p.expectName()
		p.expectOp("=")
		e := p.parseExpr()
		p.expectEnd()
		return &setStmt{name: name, e: e}
	case "macro":
		return p.parseMacro()
	case "include":
		e := p.parseExpr()
		p.expectEnd()
		return &includeStmt{e: e}
	case "extends":
		if p.depth > 0 || p.hasExtends {
			throw(KindSyntax, "misplaced extends")
		}
		p.hasExtends = true
		e := p.parseExpr()
		p.expectEnd()
		return &extendsStmt{e: e}
	case "block":
		return p.parseBlock()
	}
	throw(KindSyntax, "unknown statement %q", kw)
	return nil
}

func (p *parser) parseIf() stmt {
	s := &ifStmt{}
	for {
		cond := p.parseExpr()
		p.expectEnd()
		body, term := p.parseNested()
		s.conds = append(s.conds, cond)
		s.bodies = append(s.bodies, body)
		switch term {
		case "elif":
			continue
		case "else":
			p.expectEnd()
			var t2 string
			s.elseBody, t2 = p.parseNested()
			if t2 != "endif" {
				throw(KindSyntax, "expected endif")
			}
			p.expectEnd()
			return s
		case "endif":
			p.expectEnd()
			return s
		}
		throw(KindSyntax, "unclosed if")
	}
}

func (p *parser) parseFor() stmt {
	name := p.expectName()
	p.expectKeyword("in")
	iter := p.parseExpr()
	p.expectEnd()
	s := &forStmt{name: name, iter: iter}
	body, term := p.parseNested()
	s.body = body
	switch term {
	case "else":
		p.expectEnd()
		var t2 string
		s.elseBody, t2 = p.parseNested()
		if t2 != "endfor" {
			throw(KindSyntax, "expected endfor")
		}
	case "endfor":
	default:
		throw(KindSyntax, "unclosed for")
	}
	p.expectEnd()
	return s
}

func (p *parser) parseMacro() stmt {
	name := p.expectName()
	p.expectOp("(")
	m := &macroStmt{name: name}
	seen := map[string]bool{}
	for !p.peekOp(")") {
		pname := p.expectName()
		if seen[pname] {
			throw(KindSyntax, "duplicate macro parameter %q", pname)
		}
		seen[pname] = true
		param := macroParam{name: pname}
		if p.peekOp("=") {
			p.tp++
			param.def = p.parseExpr()
		}
		m.params = append(m.params, param)
		if p.peekOp(",") {
			p.tp++
		} else if !p.peekOp(")") {
			throw(KindSyntax, "expected ',' or ')' in macro parameters")
		}
	}
	p.tp++ // ')'
	p.expectEnd()
	body, term := p.parseNested()
	if term != "endmacro" {
		throw(KindSyntax, "unclosed macro")
	}
	p.expectEnd()
	m.body = body
	return m
}

func (p *parser) parseBlock() stmt {
	name := p.expectName()
	p.expectEnd()
	if _, dup := p.blocks[name]; dup {
		throw(KindSyntax, "duplicate block %q", name)
	}
	b := &blockStmt{name: name}
	p.blocks[name] = b
	body, term := p.parseNested()
	if term != "endblock" {
		throw(KindSyntax, "unclosed block")
	}
	if p.tp < len(p.toks) {
		if end := p.expectName(); end != name {
			throw(KindSyntax, "endblock name %q does not match block %q", end, name)
		}
	}
	p.expectEnd()
	b.body = body
	return b
}

// Token helpers.

func (p *parser) peek() (token, bool) {
	if p.tp < len(p.toks) {
		return p.toks[p.tp], true
	}
	return token{}, false
}

func (p *parser) peekOp(op string) bool {
	t, ok := p.peek()
	return ok && t.kind == tOp && t.s == op
}

func (p *parser) peekKeyword(kw string) bool {
	t, ok := p.peek()
	return ok && t.kind == tName && t.s == kw
}

func (p *parser) peekKeywordAt(off int, kw string) bool {
	i := p.tp + off
	return i < len(p.toks) && p.toks[i].kind == tName && p.toks[i].s == kw
}

func (p *parser) expectOp(op string) {
	if !p.peekOp(op) {
		throw(KindSyntax, "expected %q", op)
	}
	p.tp++
}

func (p *parser) expectKeyword(kw string) {
	if !p.peekKeyword(kw) {
		throw(KindSyntax, "expected %q", kw)
	}
	p.tp++
}

func (p *parser) expectName() string {
	t, ok := p.peek()
	if !ok || t.kind != tName || keywords[t.s] {
		throw(KindSyntax, "expected a name")
	}
	p.tp++
	return t.s
}

func (p *parser) expectEnd() {
	if p.tp != len(p.toks) {
		throw(KindSyntax, "unexpected tokens at end of tag")
	}
}

// Expressions, lowest to highest precedence.

func (p *parser) parseExpr() expr { return p.parseOr() }

func (p *parser) parseOr() expr {
	l := p.parseAnd()
	for p.peekKeyword("or") {
		p.tp++
		l = &boolExpr{and: false, l: l, r: p.parseAnd()}
	}
	return l
}

func (p *parser) parseAnd() expr {
	l := p.parseNot()
	for p.peekKeyword("and") {
		p.tp++
		l = &boolExpr{and: true, l: l, r: p.parseNot()}
	}
	return l
}

func (p *parser) parseNot() expr {
	if p.peekKeyword("not") {
		p.tp++
		return &notExpr{x: p.parseNot()}
	}
	return p.parseCompare()
}

var cmpOps = map[string]opcode{
	"==": opEq, "!=": opNe, "<": opLt, "<=": opLe, ">": opGt, ">=": opGe,
}

func (p *parser) parseCompare() expr {
	first := p.parseAdditive()
	var ops []opcode
	var rest []expr
	for {
		t, ok := p.peek()
		if !ok {
			break
		}
		var op opcode
		switch {
		case t.kind == tOp && cmpOps[t.s] != 0:
			op = cmpOps[t.s]
			p.tp++
		case t.kind == tName && t.s == "in":
			op = opIn
			p.tp++
		case t.kind == tName && t.s == "not" && p.peekKeywordAt(1, "in"):
			op = opNotIn
			p.tp += 2
		default:
			op = 0
		}
		if op == 0 {
			break
		}
		ops = append(ops, op)
		rest = append(rest, p.parseAdditive())
	}
	if len(ops) == 0 {
		return first
	}
	return &compareExpr{first: first, ops: ops, rest: rest}
}

func (p *parser) parseAdditive() expr {
	l := p.parseConcat()
	for {
		switch {
		case p.peekOp("+"):
			p.tp++
			l = &binaryExpr{op: opAdd, l: l, r: p.parseConcat()}
		case p.peekOp("-"):
			p.tp++
			l = &binaryExpr{op: opSub, l: l, r: p.parseConcat()}
		default:
			return l
		}
	}
}

func (p *parser) parseConcat() expr {
	l := p.parseTerm()
	for p.peekOp("~") {
		p.tp++
		l = &binaryExpr{op: opConcat, l: l, r: p.parseTerm()}
	}
	return l
}

func (p *parser) parseTerm() expr {
	l := p.parsePower()
	for {
		var op opcode
		switch {
		case p.peekOp("*"):
			op = opMul
		case p.peekOp("/"):
			op = opDiv
		case p.peekOp("//"):
			op = opFloorDiv
		case p.peekOp("%"):
			op = opMod
		default:
			return l
		}
		p.tp++
		l = &binaryExpr{op: op, l: l, r: p.parsePower()}
	}
}

func (p *parser) parsePower() expr {
	l := p.parseFiltered()
	for p.peekOp("**") {
		p.tp++
		l = &binaryExpr{op: opPow, l: l, r: p.parseFiltered()}
	}
	return l
}

func (p *parser) parseFiltered() expr {
	x := p.parseUnary()
	for {
		switch {
		case p.peekOp("|"):
			p.tp++
			name := p.expectFilterName()
			f := &filterExpr{x: x, name: name, def: filterTable[name]}
			if f.def == nil && p.badFilter == "" {
				p.badFilter = name
			}
			if p.peekOp("(") {
				p.tp++
				f.args = p.parseArgList()
			}
			x = f
		case p.peekKeyword("is"):
			p.tp++
			neg := false
			if p.peekKeyword("not") {
				p.tp++
				neg = true
			}
			if !p.peekKeyword("defined") {
				throw(KindSyntax, "unknown test")
			}
			p.tp++
			x = &definedExpr{x: x, negate: neg}
		default:
			return x
		}
	}
}

func (p *parser) expectFilterName() string {
	t, ok := p.peek()
	if !ok || t.kind != tName {
		throw(KindSyntax, "expected a filter name")
	}
	p.tp++
	return t.s
}

// parseArgList parses filter arguments after '(' up to and including ')'.
func (p *parser) parseArgList() []expr {
	var args []expr
	if p.peekOp(")") {
		p.tp++
		return args
	}
	for {
		args = append(args, p.parseExpr())
		if p.peekOp(",") {
			p.tp++
			continue
		}
		p.expectOp(")")
		return args
	}
}

func (p *parser) parseUnary() expr {
	if p.peekOp("-") {
		p.tp++
		return &negExpr{x: p.parseUnary()}
	}
	return p.parsePostfix()
}

func (p *parser) parsePostfix() expr {
	x := p.parsePrimary()
	for {
		switch {
		case p.peekOp("."):
			p.tp++
			t, ok := p.peek()
			if !ok || t.kind != tName {
				throw(KindSyntax, "expected an attribute name")
			}
			p.tp++
			x = &attrExpr{x: x, name: t.s}
		case p.peekOp("["):
			p.tp++
			k := p.parseExpr()
			p.expectOp("]")
			x = &indexExpr{x: x, key: k}
		case p.peekOp("("):
			p.tp++
			x = p.parseCall(x)
		default:
			return x
		}
	}
}

func (p *parser) parseCall(fn expr) expr {
	c := &callExpr{fn: fn}
	if p.peekOp(")") {
		p.tp++
		return c
	}
	for {
		t, _ := p.peek()
		if t.kind == tName && !keywords[t.s] && p.tp+1 < len(p.toks) && p.toks[p.tp+1].kind == tOp && p.toks[p.tp+1].s == "=" {
			for _, n := range c.kwNames {
				if n == t.s {
					throw(KindSyntax, "repeated keyword argument %q", t.s)
				}
			}
			p.tp += 2
			c.kwNames = append(c.kwNames, t.s)
			c.kwArgs = append(c.kwArgs, p.parseExpr())
		} else {
			if len(c.kwNames) > 0 {
				throw(KindSyntax, "positional argument after keyword argument")
			}
			c.args = append(c.args, p.parseExpr())
		}
		if p.peekOp(",") {
			p.tp++
			continue
		}
		p.expectOp(")")
		return c
	}
}

func (p *parser) parsePrimary() expr {
	t, ok := p.peek()
	if !ok {
		throw(KindSyntax, "unexpected end of expression")
	}
	p.tp++
	switch t.kind {
	case tInt:
		return &litExpr{v: t.i}
	case tFloat:
		return &litExpr{v: t.f}
	case tString:
		return &litExpr{v: t.s}
	case tName:
		switch t.s {
		case "true":
			return &litExpr{v: true}
		case "false":
			return &litExpr{v: false}
		case "none":
			return &litExpr{v: None}
		}
		if keywords[t.s] {
			throw(KindSyntax, "unexpected keyword %q", t.s)
		}
		return &nameExpr{name: t.s}
	case tOp:
		switch t.s {
		case "(":
			e := p.parseExpr()
			p.expectOp(")")
			return e
		case "[":
			l := &listExpr{}
			if p.peekOp("]") {
				p.tp++
				return l
			}
			for {
				l.elems = append(l.elems, p.parseExpr())
				if p.peekOp(",") {
					p.tp++
					continue
				}
				p.expectOp("]")
				return l
			}
		}
	}
	throw(KindSyntax, "unexpected token in expression")
	return nil
}
