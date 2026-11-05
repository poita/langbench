package template

import "fmt"

// parseTemplate lexes and parses src and checks its filter names. Any failure
// is returned as an *Error: syntax problems take precedence over unknown
// filters.
func parseTemplate(name, src string) (t *Template, err error) {
	defer recoverError(&err)
	p := &parser{items: lex(src), tpl: &Template{name: name}, blockNames: map[string]bool{}}
	body, term := p.parseBody(true, nil)
	if term != "" {
		throw(ErrSyntax, "unexpected %q", term)
	}
	if p.unknownFilter != "" {
		throw(ErrFilter, "unknown filter %q", p.unknownFilter)
	}
	p.tpl.body = body
	return p.tpl, nil
}

type parser struct {
	items         []item
	pos           int
	tpl           *Template
	blockNames    map[string]bool
	hasExtends    bool
	termToks      []token // tokens after the keyword of the last terminator
	unknownFilter string
}

var keywords = map[string]bool{
	"and": true, "or": true, "not": true, "in": true, "is": true,
	"true": true, "false": true, "none": true,
}

// parseBody parses items until a statement whose keyword is in terms (it is
// consumed and its name returned together with its tokens) or the end of the
// template. top reports whether the body is the template's top level.
func (p *parser) parseBody(top bool, terms []string) (body []Stmt, term string) {
	for p.pos < len(p.items) {
		it := p.items[p.pos]
		p.pos++
		switch it.kind {
		case itText:
			body = append(body, &textStmt{it.text})
		case itPrint:
			tp := &tokParser{p: p, toks: it.toks}
			x := tp.parseExpr()
			tp.expectEnd()
			body = append(body, &printStmt{x})
		case itStmt:
			if len(it.toks) == 0 || it.toks[0].kind != tkName {
				throw(ErrSyntax, "empty or malformed statement")
			}
			kw := it.toks[0].s
			for _, t := range terms {
				if t == kw {
					p.termToks = it.toks[1:]
					return body, kw
				}
			}
			tp := &tokParser{p: p, toks: it.toks, pos: 1}
			body = append(body, p.parseStmt(kw, tp, top))
		}
	}
	if len(terms) > 0 {
		throw(ErrSyntax, "unexpected end of template, expected %q", terms[0])
	}
	return body, ""
}

func (p *parser) parseStmt(kw string, tp *tokParser, top bool) Stmt {
	switch kw {
	case "if":
		s := &ifStmt{}
		cond := tp.parseExpr()
		tp.expectEnd()
		for {
			body, term := p.parseBody(false, []string{"elif", "else", "endif"})
			s.conds = append(s.conds, cond)
			s.bodies = append(s.bodies, body)
			switch term {
			case "elif":
				etp := &tokParser{p: p, toks: p.termToks}
				cond = etp.parseExpr()
				etp.expectEnd()
				continue
			case "else":
				p.expectNoToks()
				s.elseBody, term = p.parseBody(false, []string{"endif"})
				_ = term
				p.expectNoToks()
			case "endif":
				p.expectNoToks()
			}
			return s
		}
	case "for":
		s := &forStmt{}
		s.name = tp.expectIdent()
		tp.expectKeyword("in")
		s.iter = tp.parseExpr()
		tp.expectEnd()
		var term string
		s.body, term = p.parseBody(false, []string{"else", "endfor"})
		p.expectNoToks()
		if term == "else" {
			s.elseBody, _ = p.parseBody(false, []string{"endfor"})
			p.expectNoToks()
		}
		return s
	case "set":
		name := tp.expectIdent()
		tp.expectOp("=")
		x := tp.parseExpr()
		tp.expectEnd()
		return &setStmt{name, x}
	case "macro":
		d := &macroDef{name: tp.expectIdent()}
		tp.expectOp("(")
		if !tp.isOp(")") {
			for {
				pn := tp.expectIdent()
				for _, o := range d.params {
					if o == pn {
						throw(ErrSyntax, "duplicate macro parameter %q", pn)
					}
				}
				var def Expr
				if tp.isOp("=") {
					tp.pos++
					def = tp.parseExpr()
				}
				d.params = append(d.params, pn)
				d.defaults = append(d.defaults, def)
				if tp.isOp(",") {
					tp.pos++
					continue
				}
				break
			}
		}
		tp.expectOp(")")
		tp.expectEnd()
		d.body, _ = p.parseBody(false, []string{"endmacro"})
		p.expectNoToks()
		return &macroStmt{d}
	case "include":
		x := tp.parseExpr()
		tp.expectEnd()
		return &includeStmt{x}
	case "extends":
		if !top || p.hasExtends {
			throw(ErrSyntax, "misplaced or repeated extends")
		}
		p.hasExtends = true
		x := tp.parseExpr()
		tp.expectEnd()
		return &extendsStmt{x}
	case "block":
		name := tp.expectIdent()
		tp.expectEnd()
		if p.blockNames[name] {
			throw(ErrSyntax, "duplicate block %q", name)
		}
		p.blockNames[name] = true
		d := &blockDef{name: name}
		p.tpl.blocks = append(p.tpl.blocks, d)
		d.body, _ = p.parseBody(false, []string{"endblock"})
		if len(p.termToks) > 0 {
			etp := &tokParser{p: p, toks: p.termToks}
			if etp.expectIdent() != name {
				throw(ErrSyntax, "endblock name does not match block %q", name)
			}
			etp.expectEnd()
		}
		return &blockStmt{d}
	}
	throw(ErrSyntax, "unknown statement %q", kw)
	return nil
}

func (p *parser) expectNoToks() {
	if len(p.termToks) != 0 {
		throw(ErrSyntax, "unexpected tokens after statement keyword")
	}
}

// tokParser is a recursive-descent expression parser over one tag's tokens.
type tokParser struct {
	p    *parser
	toks []token
	pos  int
}

func (tp *tokParser) fail(what string) {
	throw(ErrSyntax, "%s", what)
}

func (tp *tokParser) peek() *token {
	if tp.pos < len(tp.toks) {
		return &tp.toks[tp.pos]
	}
	return nil
}

func (tp *tokParser) isOp(s string) bool {
	t := tp.peek()
	return t != nil && t.kind == tkOp && t.s == s
}

func (tp *tokParser) isKeyword(s string) bool {
	t := tp.peek()
	return t != nil && t.kind == tkName && t.s == s
}

func (tp *tokParser) expectOp(s string) {
	if !tp.isOp(s) {
		tp.fail(fmt.Sprintf("expected %q", s))
	}
	tp.pos++
}

func (tp *tokParser) expectKeyword(s string) {
	if !tp.isKeyword(s) {
		tp.fail(fmt.Sprintf("expected %q", s))
	}
	tp.pos++
}

func (tp *tokParser) expectIdent() string {
	t := tp.peek()
	if t == nil || t.kind != tkName || keywords[t.s] {
		tp.fail("expected a name")
	}
	tp.pos++
	return t.s
}

func (tp *tokParser) expectEnd() {
	if tp.pos != len(tp.toks) {
		tp.fail("unexpected tokens at end of tag")
	}
}

func (tp *tokParser) parseExpr() Expr { return tp.parseOr() }

func (tp *tokParser) parseOr() Expr {
	l := tp.parseAnd()
	for tp.isKeyword("or") {
		tp.pos++
		l = &orExpr{l, tp.parseAnd()}
	}
	return l
}

func (tp *tokParser) parseAnd() Expr {
	l := tp.parseNot()
	for tp.isKeyword("and") {
		tp.pos++
		l = &andExpr{l, tp.parseNot()}
	}
	return l
}

func (tp *tokParser) parseNot() Expr {
	if tp.isKeyword("not") {
		tp.pos++
		return &notExpr{tp.parseNot()}
	}
	return tp.parseCompare()
}

func (tp *tokParser) parseCompare() Expr {
	first := tp.parseAdditive()
	var ops []cmpOp
	var rest []Expr
	for {
		t := tp.peek()
		if t == nil {
			break
		}
		var op cmpOp
		switch {
		case t.kind == tkOp && t.s == "==":
			op = cmpEq
		case t.kind == tkOp && t.s == "!=":
			op = cmpNe
		case t.kind == tkOp && t.s == "<":
			op = cmpLt
		case t.kind == tkOp && t.s == "<=":
			op = cmpLe
		case t.kind == tkOp && t.s == ">":
			op = cmpGt
		case t.kind == tkOp && t.s == ">=":
			op = cmpGe
		case t.kind == tkName && t.s == "in":
			op = cmpIn
		case t.kind == tkName && t.s == "not" && tp.pos+1 < len(tp.toks) &&
			tp.toks[tp.pos+1].kind == tkName && tp.toks[tp.pos+1].s == "in":
			op = cmpNotIn
			tp.pos++
		default:
			goto done
		}
		tp.pos++
		ops = append(ops, op)
		rest = append(rest, tp.parseAdditive())
	}
done:
	if len(ops) == 0 {
		return first
	}
	return &cmpExpr{first, ops, rest}
}

// binLevel parses a left-associative level of binary operators.
func (tp *tokParser) binLevel(sub func() Expr, ops map[string]binOp) Expr {
	l := sub()
	for {
		t := tp.peek()
		if t == nil || t.kind != tkOp {
			return l
		}
		op, ok := ops[t.s]
		if !ok {
			return l
		}
		tp.pos++
		l = &binExpr{op, l, sub()}
	}
}

var (
	additiveOps = map[string]binOp{"+": opAdd, "-": opSub}
	concatOps   = map[string]binOp{"~": opConcat}
	termOps     = map[string]binOp{"*": opMul, "/": opDiv, "//": opFloorDiv, "%": opMod}
	powerOps    = map[string]binOp{"**": opPow}
)

func (tp *tokParser) parseAdditive() Expr { return tp.binLevel(tp.parseConcat, additiveOps) }
func (tp *tokParser) parseConcat() Expr   { return tp.binLevel(tp.parseTerm, concatOps) }
func (tp *tokParser) parseTerm() Expr     { return tp.binLevel(tp.parsePower, termOps) }
func (tp *tokParser) parsePower() Expr    { return tp.binLevel(tp.parseFiltered, powerOps) }

func (tp *tokParser) parseFiltered() Expr {
	x := tp.parseUnary()
	for {
		switch {
		case tp.isOp("|"):
			tp.pos++
			t := tp.peek()
			if t == nil || t.kind != tkName || keywords[t.s] {
				tp.fail("expected filter name")
			}
			tp.pos++
			code, ok := filterCodes[t.s]
			if !ok && tp.p.unknownFilter == "" {
				tp.p.unknownFilter = t.s
			}
			var args []Expr
			if tp.isOp("(") {
				tp.pos++
				if tp.isOp(")") {
					tp.pos++
				} else {
					for {
						args = append(args, tp.parseExpr())
						if tp.isOp(",") {
							tp.pos++
							continue
						}
						tp.expectOp(")")
						break
					}
				}
			}
			x = &filterExpr{x, code, args}
		case tp.isKeyword("is"):
			tp.pos++
			neg := false
			if tp.isKeyword("not") {
				tp.pos++
				neg = true
			}
			if !tp.isKeyword("defined") {
				tp.fail("only the 'defined' test exists")
			}
			tp.pos++
			x = &definedExpr{x, neg}
		default:
			return x
		}
	}
}

func (tp *tokParser) parseUnary() Expr {
	if tp.isOp("-") {
		tp.pos++
		return &negExpr{tp.parseUnary()}
	}
	return tp.parsePostfix()
}

func (tp *tokParser) parsePostfix() Expr {
	x := tp.parsePrimary()
	for {
		switch {
		case tp.isOp("."):
			tp.pos++
			t := tp.peek()
			if t == nil || t.kind != tkName {
				tp.fail("expected attribute name")
			}
			tp.pos++
			x = &attrExpr{x, t.s}
		case tp.isOp("["):
			tp.pos++
			idx := tp.parseExpr()
			tp.expectOp("]")
			x = &indexExpr{x, idx}
		case tp.isOp("("):
			tp.pos++
			x = tp.parseCall(x)
		default:
			return x
		}
	}
}

func (tp *tokParser) parseCall(fn Expr) Expr {
	c := &callExpr{fn: fn}
	if tp.isOp(")") {
		tp.pos++
		return c
	}
	for {
		t := tp.peek()
		if t != nil && t.kind == tkName && !keywords[t.s] &&
			tp.pos+1 < len(tp.toks) && tp.toks[tp.pos+1].kind == tkOp && tp.toks[tp.pos+1].s == "=" {
			for _, n := range c.kwNames {
				if n == t.s {
					tp.fail("repeated keyword argument")
				}
			}
			tp.pos += 2
			c.kwNames = append(c.kwNames, t.s)
			c.kwVals = append(c.kwVals, tp.parseExpr())
		} else {
			if len(c.kwNames) > 0 {
				tp.fail("positional argument after keyword argument")
			}
			c.args = append(c.args, tp.parseExpr())
		}
		if tp.isOp(",") {
			tp.pos++
			continue
		}
		tp.expectOp(")")
		return c
	}
}

func (tp *tokParser) parsePrimary() Expr {
	t := tp.peek()
	if t == nil {
		tp.fail("unexpected end of expression")
	}
	tp.pos++
	switch t.kind {
	case tkInt:
		return &constExpr{t.i}
	case tkFloat:
		return &constExpr{t.f}
	case tkString:
		return &constExpr{t.s}
	case tkName:
		switch t.s {
		case "true":
			return &constExpr{true}
		case "false":
			return &constExpr{false}
		case "none":
			return &constExpr{None}
		}
		if keywords[t.s] {
			tp.fail("unexpected keyword " + t.s)
		}
		return &nameExpr{name: t.s, isRange: t.s == "range"}
	case tkOp:
		switch t.s {
		case "[":
			l := &listExpr{}
			if tp.isOp("]") {
				tp.pos++
				return l
			}
			for {
				l.elems = append(l.elems, tp.parseExpr())
				if tp.isOp(",") {
					tp.pos++
					continue
				}
				tp.expectOp("]")
				return l
			}
		case "(":
			x := tp.parseExpr()
			tp.expectOp(")")
			return x
		}
	}
	tp.fail("unexpected token in expression")
	return nil
}
