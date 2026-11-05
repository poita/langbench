package tmpl

type parser struct {
	items      []rawItem
	pos        int
	blocks     map[string]*blockDef
	depth      int // nesting depth of if/for/block/macro bodies
	hasExtends bool
	macros     int // macros parsed so far (to detect macros inside loop bodies)
	badFilter  string
}

// parseTemplate lexes and parses src. Syntax problems raise a syntax error;
// an unknown filter, which is only reported after the whole template parsed,
// raises a filter error.
func parseTemplate(name, src string) *template {
	p := &parser{items: lex(src), blocks: map[string]*blockDef{}}
	body, stop := p.parseBody()
	if stop != nil {
		fail(SyntaxError, "unexpected end of template")
	}
	if p.badFilter != "" {
		fail(FilterError, "no filter named %q", p.badFilter)
	}
	return &template{name: name, body: body, blocks: p.blocks}
}

// parseBody parses statements until a statement tag whose keyword is in
// stops, which is returned (unparsed); it returns nil at the end of the
// template, which is an error when stops is non-empty.
func (p *parser) parseBody(stops ...string) (body []stmt, stop *rawItem) {
	for p.pos < len(p.items) {
		it := &p.items[p.pos]
		p.pos++
		switch it.kind {
		case rawText:
			body = append(body, &textStmt{text: it.text})
		case rawVar:
			c := &cursor{toks: it.toks, p: p}
			x := c.parseExpr()
			c.expectEnd()
			body = append(body, &printStmt{x: x})
		case rawStmt:
			if len(it.toks) == 0 || it.toks[0].kind != tName {
				fail(SyntaxError, "invalid statement")
			}
			kw := it.toks[0].s
			for _, s := range stops {
				if s == kw {
					return body, it
				}
			}
			body = append(body, p.parseStmt(kw, &cursor{toks: it.toks[1:], p: p}))
		}
	}
	if len(stops) > 0 {
		fail(SyntaxError, "unexpected end of template: missing {%% %s %%}", stops[len(stops)-1])
	}
	return body, nil
}

// nested parses a body one nesting level deeper.
func (p *parser) nested(stops ...string) ([]stmt, *rawItem) {
	p.depth++
	body, stop := p.parseBody(stops...)
	p.depth--
	return body, stop
}

func endCursor(it *rawItem, p *parser) *cursor { return &cursor{toks: it.toks[1:], p: p} }

func (p *parser) parseStmt(kw string, c *cursor) stmt {
	switch kw {
	case "if":
		return p.parseIf(c)
	case "for":
		return p.parseFor(c)
	case "set":
		name := c.expectName()
		c.expectOp("=")
		x := c.parseExpr()
		c.expectEnd()
		return &setStmt{name: name, x: x}
	case "macro":
		return p.parseMacro(c)
	case "include":
		x := c.parseExpr()
		c.expectEnd()
		return &includeStmt{x: x}
	case "extends":
		if p.depth > 0 || p.hasExtends {
			fail(SyntaxError, "misplaced extends")
		}
		p.hasExtends = true
		x := c.parseExpr()
		c.expectEnd()
		return &extendsStmt{x: x}
	case "block":
		return p.parseBlock(c)
	}
	fail(SyntaxError, "unknown statement %q", kw)
	return nil
}

func (p *parser) parseIf(c *cursor) stmt {
	s := &ifStmt{}
	cond := c.parseExpr()
	c.expectEnd()
	for {
		body, stop := p.nested("elif", "else", "endif")
		s.conds = append(s.conds, cond)
		s.bodies = append(s.bodies, body)
		sc := endCursor(stop, p)
		switch stop.toks[0].s {
		case "elif":
			cond = sc.parseExpr()
			sc.expectEnd()
		case "else":
			sc.expectEnd()
			var end *rawItem
			s.elseBody, end = p.nested("endif")
			endCursor(end, p).expectEnd()
			return s
		default:
			sc.expectEnd()
			return s
		}
	}
}

func (p *parser) parseFor(c *cursor) stmt {
	s := &forStmt{name: c.expectName()}
	c.expectKeyword("in")
	s.iter = c.parseExpr()
	c.expectEnd()
	macros := p.macros
	body, stop := p.nested("else", "endfor")
	s.body = body
	s.reuse = p.macros == macros
	sc := endCursor(stop, p)
	sc.expectEnd()
	if stop.toks[0].s == "else" {
		var end *rawItem
		s.elseBody, end = p.nested("endfor")
		endCursor(end, p).expectEnd()
	}
	return s
}

func (p *parser) parseMacro(c *cursor) stmt {
	m := &macroDef{name: c.expectName()}
	c.expectOp("(")
	for !c.acceptOp(")") {
		pr := param{name: c.expectName()}
		for _, o := range m.params {
			if o.name == pr.name {
				fail(SyntaxError, "duplicate macro parameter %q", pr.name)
			}
		}
		if c.acceptOp("=") {
			pr.def = c.parseExpr()
		}
		m.params = append(m.params, pr)
		if !c.acceptOp(",") {
			c.expectOp(")")
			break
		}
	}
	c.expectEnd()
	p.macros++
	body, end := p.nested("endmacro")
	endCursor(end, p).expectEnd()
	m.body = body
	return m
}

func (p *parser) parseBlock(c *cursor) stmt {
	name := c.expectName()
	c.expectEnd()
	if _, dup := p.blocks[name]; dup {
		fail(SyntaxError, "block %q defined twice", name)
	}
	b := &blockDef{name: name}
	p.blocks[name] = b
	body, end := p.nested("endblock")
	ec := endCursor(end, p)
	if t := ec.peek(); t != nil {
		if ec.expectName() != name {
			fail(SyntaxError, "endblock name does not match block %q", name)
		}
	}
	ec.expectEnd()
	b.body = body
	return b
}

// ---- token cursor and expression parser ----

type cursor struct {
	toks []token
	pos  int
	p    *parser
}

func (c *cursor) peek() *token {
	if c.pos < len(c.toks) {
		return &c.toks[c.pos]
	}
	return nil
}

func (c *cursor) isOp(s string) bool {
	t := c.peek()
	return t != nil && t.kind == tOp && t.s == s
}

func (c *cursor) isKeyword(s string) bool {
	t := c.peek()
	return t != nil && t.kind == tName && t.s == s
}

func (c *cursor) acceptOp(s string) bool {
	if c.isOp(s) {
		c.pos++
		return true
	}
	return false
}

func (c *cursor) acceptKeyword(s string) bool {
	if c.isKeyword(s) {
		c.pos++
		return true
	}
	return false
}

func (c *cursor) expectOp(s string) {
	if !c.acceptOp(s) {
		fail(SyntaxError, "expected %q", s)
	}
}

func (c *cursor) expectKeyword(s string) {
	if !c.acceptKeyword(s) {
		fail(SyntaxError, "expected %q", s)
	}
}

func (c *cursor) expectEnd() {
	if c.pos != len(c.toks) {
		fail(SyntaxError, "unexpected token in tag")
	}
}

func isReserved(s string) bool {
	switch s {
	case "and", "or", "not", "in", "is", "true", "false", "none":
		return true
	}
	return false
}

// expectName consumes a non-reserved name.
func (c *cursor) expectName() string {
	t := c.peek()
	if t == nil || t.kind != tName || isReserved(t.s) {
		fail(SyntaxError, "expected a name")
	}
	c.pos++
	return t.s
}

func (c *cursor) parseExpr() expr { return c.parseOr() }

func (c *cursor) parseOr() expr {
	l := c.parseAnd()
	for c.acceptKeyword("or") {
		l = &orExpr{l, c.parseAnd()}
	}
	return l
}

func (c *cursor) parseAnd() expr {
	l := c.parseNot()
	for c.acceptKeyword("and") {
		l = &andExpr{l, c.parseNot()}
	}
	return l
}

func (c *cursor) parseNot() expr {
	if c.acceptKeyword("not") {
		return &notExpr{c.parseNot()}
	}
	return c.parseCompare()
}

var cmpOps = map[string]cmpOp{"==": cmpEq, "!=": cmpNe, "<": cmpLt, "<=": cmpLe, ">": cmpGt, ">=": cmpGe}

func (c *cursor) parseCompare() expr {
	first := c.parseAdditive()
	var ce *cmpExpr
	for {
		t := c.peek()
		if t == nil {
			break
		}
		var op cmpOp
		switch {
		case t.kind == tOp && hasCmp(t.s):
			op = cmpOps[t.s]
			c.pos++
		case t.kind == tName && t.s == "in":
			op = cmpIn
			c.pos++
		case t.kind == tName && t.s == "not" && c.pos+1 < len(c.toks) &&
			c.toks[c.pos+1].kind == tName && c.toks[c.pos+1].s == "in":
			op = cmpNotIn
			c.pos += 2
		default:
			if ce == nil {
				return first
			}
			return ce
		}
		if ce == nil {
			ce = &cmpExpr{first: first}
		}
		ce.ops = append(ce.ops, op)
		ce.rest = append(ce.rest, c.parseAdditive())
	}
	if ce == nil {
		return first
	}
	return ce
}

func hasCmp(s string) bool { _, ok := cmpOps[s]; return ok }

func (c *cursor) parseAdditive() expr {
	l := c.parseConcat()
	for {
		switch {
		case c.acceptOp("+"):
			l = &binExpr{opAdd, l, c.parseConcat()}
		case c.acceptOp("-"):
			l = &binExpr{opSub, l, c.parseConcat()}
		default:
			return l
		}
	}
}

func (c *cursor) parseConcat() expr {
	l := c.parseTerm()
	for c.acceptOp("~") {
		l = &binExpr{opConcat, l, c.parseTerm()}
	}
	return l
}

func (c *cursor) parseTerm() expr {
	l := c.parsePower()
	for {
		switch {
		case c.acceptOp("*"):
			l = &binExpr{opMul, l, c.parsePower()}
		case c.acceptOp("//"):
			l = &binExpr{opFloorDiv, l, c.parsePower()}
		case c.acceptOp("/"):
			l = &binExpr{opDiv, l, c.parsePower()}
		case c.acceptOp("%"):
			l = &binExpr{opMod, l, c.parsePower()}
		default:
			return l
		}
	}
}

func (c *cursor) parsePower() expr {
	l := c.parseFiltered()
	for c.acceptOp("**") {
		l = &binExpr{opPow, l, c.parseFiltered()}
	}
	return l
}

func (c *cursor) parseFiltered() expr {
	x := c.parseUnary()
	for {
		switch {
		case c.acceptOp("|"):
			name := c.expectFilterName()
			code, ok := filterCodes[name]
			if !ok {
				code = filterUnknown
				if c.p.badFilter == "" {
					c.p.badFilter = name
				}
			}
			var args []expr
			if c.acceptOp("(") {
				if !c.acceptOp(")") {
					for {
						args = append(args, c.parseExpr())
						if c.acceptOp(")") {
							break
						}
						c.expectOp(",")
					}
				}
			}
			x = &filterExpr{x: x, code: code, args: args}
		case c.acceptKeyword("is"):
			neg := c.acceptKeyword("not")
			if t := c.peek(); t == nil || t.kind != tName || t.s != "defined" {
				fail(SyntaxError, "unknown test")
			}
			c.pos++
			x = &definedExpr{x: x, neg: neg}
		default:
			return x
		}
	}
}

func (c *cursor) expectFilterName() string {
	t := c.peek()
	if t == nil || t.kind != tName {
		fail(SyntaxError, "expected a filter name")
	}
	c.pos++
	return t.s
}

func (c *cursor) parseUnary() expr {
	if c.acceptOp("-") {
		return &negExpr{c.parseUnary()}
	}
	return c.parsePostfix()
}

func (c *cursor) parsePostfix() expr {
	x := c.parsePrimary()
	for {
		switch {
		case c.acceptOp("."):
			t := c.peek()
			if t == nil || t.kind != tName {
				fail(SyntaxError, "expected an attribute name")
			}
			c.pos++
			x = &attrExpr{obj: x, key: t.s}
		case c.acceptOp("["):
			idx := c.parseExpr()
			c.expectOp("]")
			x = &indexExpr{x, idx}
		case c.acceptOp("("):
			x = c.parseCall(x)
		default:
			return x
		}
	}
}

func (c *cursor) parseCall(fn expr) expr {
	call := &callExpr{fn: fn}
	if c.acceptOp(")") {
		return call
	}
	for {
		// A keyword argument is NAME "=" expr.
		if t := c.peek(); t != nil && t.kind == tName && c.pos+1 < len(c.toks) &&
			c.toks[c.pos+1].kind == tOp && c.toks[c.pos+1].s == "=" {
			name := c.expectName()
			for _, k := range call.kwNames {
				if k == name {
					fail(SyntaxError, "keyword argument repeated")
				}
			}
			c.pos++ // '='
			call.kwNames = append(call.kwNames, name)
			call.kwVals = append(call.kwVals, c.parseExpr())
		} else {
			if len(call.kwNames) > 0 {
				fail(SyntaxError, "positional argument after keyword argument")
			}
			call.args = append(call.args, c.parseExpr())
		}
		if c.acceptOp(")") {
			return call
		}
		c.expectOp(",")
	}
}

func (c *cursor) parsePrimary() expr {
	t := c.peek()
	if t == nil {
		fail(SyntaxError, "unexpected end of expression")
	}
	c.pos++
	switch t.kind {
	case tInt:
		return &litExpr{t.i}
	case tFloat:
		return &litExpr{t.f}
	case tString:
		return &litExpr{t.s}
	case tName:
		switch t.s {
		case "true":
			return &litExpr{true}
		case "false":
			return &litExpr{false}
		case "none":
			return &litExpr{nil}
		}
		if isReserved(t.s) {
			fail(SyntaxError, "unexpected keyword %q", t.s)
		}
		return &nameExpr{t.s}
	case tOp:
		switch t.s {
		case "(":
			x := c.parseExpr()
			c.expectOp(")")
			return x
		case "[":
			l := &listExpr{}
			if c.acceptOp("]") {
				return l
			}
			for {
				l.elems = append(l.elems, c.parseExpr())
				if c.acceptOp("]") {
					return l
				}
				c.expectOp(",")
			}
		}
	}
	fail(SyntaxError, "unexpected token in expression")
	return nil
}
