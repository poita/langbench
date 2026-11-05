package minisql

import "fmt"

// ErrorKind classifies statement errors.
type ErrorKind uint8

const (
	// SyntaxError: the statement does not match the grammar.
	SyntaxError ErrorKind = iota
	// SemanticError: the statement is well-formed but invalid against the
	// schema (unknown table or column, arity mismatch, misplaced aggregate...).
	SemanticError
)

// Error is the error type returned for a failing statement.
type Error struct {
	Kind ErrorKind
	Msg  string
}

func (e *Error) Error() string {
	if e.Kind == SyntaxError {
		return "syntax error: " + e.Msg
	}
	return e.Msg
}

func syntaxErr(format string, a ...any) {
	panic(&Error{SyntaxError, fmt.Sprintf(format, a...)})
}

func semErr(format string, a ...any) {
	panic(&Error{SemanticError, fmt.Sprintf(format, a...)})
}

type parser struct {
	toks []token
	pos  int
}

var eofToken = token{kind: tEOF}

func (p *parser) peek() token {
	if p.pos < len(p.toks) {
		return p.toks[p.pos]
	}
	return eofToken
}

func (p *parser) peekAt(off int) token {
	if p.pos+off < len(p.toks) {
		return p.toks[p.pos+off]
	}
	return eofToken
}

func (p *parser) next() token {
	t := p.peek()
	if p.pos < len(p.toks) {
		p.pos++
	}
	return t
}

func (t token) isKw(w string) bool { return t.kind == tKeyword && t.text == w }
func (t token) isOp(o string) bool { return t.kind == tOp && t.text == o }

func (p *parser) acceptKw(w string) bool {
	if p.peek().isKw(w) {
		p.pos++
		return true
	}
	return false
}

func (p *parser) acceptOp(o string) bool {
	if p.peek().isOp(o) {
		p.pos++
		return true
	}
	return false
}

func (p *parser) expectKw(w string) {
	if !p.acceptKw(w) {
		syntaxErr("expected %s", w)
	}
}

func (p *parser) expectOp(o string) {
	if !p.acceptOp(o) {
		syntaxErr("expected %q", o)
	}
}

func (p *parser) ident() string {
	t := p.peek()
	if t.kind != tIdent {
		syntaxErr("expected identifier")
	}
	p.pos++
	return t.text
}

func (p *parser) integer() int64 {
	t := p.peek()
	if t.kind != tInt {
		syntaxErr("expected integer")
	}
	p.pos++
	return t.ival
}

// parseStatement parses one statement (without its ';'). It panics with
// *Error on failure; callers recover.
func parseStatement(toks []token) any {
	p := &parser{toks: toks}
	var s any
	t := p.peek()
	switch {
	case t.isKw("create"):
		s = p.parseCreate()
	case t.isKw("insert"):
		s = p.parseInsert()
	case t.isKw("delete"):
		s = p.parseDelete()
	case t.isKw("update"):
		s = p.parseUpdate()
	case t.isKw("select"):
		s = p.parseSelect()
	default:
		syntaxErr("unsupported statement")
	}
	if p.pos != len(p.toks) {
		syntaxErr("unexpected token after statement")
	}
	return s
}

func (p *parser) parseCreate() *createStmt {
	p.expectKw("create")
	p.expectKw("table")
	s := &createStmt{name: p.ident()}
	p.expectOp("(")
	for {
		name := p.ident()
		t := p.next()
		if !t.isKw("integer") && !t.isKw("text") {
			syntaxErr("expected column type")
		}
		s.cols = append(s.cols, colDef{name, t.text})
		if !p.acceptOp(",") {
			break
		}
	}
	p.expectOp(")")
	return s
}

func (p *parser) parseInsert() *insertStmt {
	p.expectKw("insert")
	p.expectKw("into")
	s := &insertStmt{table: p.ident()}
	p.expectKw("values")
	for {
		p.expectOp("(")
		var row []*expr
		for {
			row = append(row, p.parseExpr())
			if !p.acceptOp(",") {
				break
			}
		}
		p.expectOp(")")
		s.rows = append(s.rows, row)
		if !p.acceptOp(",") {
			break
		}
	}
	return s
}

func (p *parser) parseDelete() *deleteStmt {
	p.expectKw("delete")
	p.expectKw("from")
	s := &deleteStmt{table: p.ident()}
	if p.acceptKw("where") {
		s.where = p.parseExpr()
	}
	return s
}

func (p *parser) parseUpdate() *updateStmt {
	p.expectKw("update")
	s := &updateStmt{table: p.ident()}
	p.expectKw("set")
	for {
		col := p.ident()
		p.expectOp("=")
		s.sets = append(s.sets, assignment{col, p.parseExpr()})
		if !p.acceptOp(",") {
			break
		}
	}
	if p.acceptKw("where") {
		s.where = p.parseExpr()
	}
	return s
}

func (p *parser) parseTableRef() tableRef {
	r := tableRef{name: p.ident()}
	if p.acceptKw("as") {
		r.alias = p.ident()
	} else if p.peek().kind == tIdent {
		r.alias = p.next().text
	}
	return r
}

func (p *parser) parseColRef() colRef {
	name := p.ident()
	if p.acceptOp(".") {
		return colRef{name, p.ident()}
	}
	return colRef{"", name}
}

func (p *parser) parseSelect() *selectStmt {
	p.expectKw("select")
	s := &selectStmt{limit: -1}
	for {
		if p.acceptOp("*") {
			s.items = append(s.items, selItem{star: true})
		} else {
			it := selItem{e: p.parseExpr()}
			if p.acceptKw("as") {
				it.alias = p.ident()
			} else if p.peek().kind == tIdent {
				it.alias = p.next().text
			}
			s.items = append(s.items, it)
		}
		if !p.acceptOp(",") {
			break
		}
	}
	if p.acceptKw("from") {
		s.from = append(s.from, p.parseTableRef())
		switch {
		case p.acceptOp(","):
			s.from = append(s.from, p.parseTableRef())
		case p.peek().isKw("inner") || p.peek().isKw("join"):
			p.acceptKw("inner")
			p.expectKw("join")
			s.from = append(s.from, p.parseTableRef())
			p.expectKw("on")
			s.on = p.parseExpr()
		}
	}
	if p.acceptKw("where") {
		s.where = p.parseExpr()
	}
	if p.acceptKw("group") {
		p.expectKw("by")
		for {
			s.groupBy = append(s.groupBy, p.parseColRef())
			if !p.acceptOp(",") {
				break
			}
		}
	}
	if p.acceptKw("having") {
		if s.groupBy == nil {
			syntaxErr("HAVING requires GROUP BY")
		}
		s.having = p.parseExpr()
	}
	if p.acceptKw("order") {
		p.expectKw("by")
		for {
			start := p.pos
			t := orderTerm{e: p.parseExpr()}
			if p.pos-start == 1 {
				switch tok := p.toks[start]; tok.kind {
				case tInt:
					t.ordinal, t.ival = true, tok.ival
				case tIdent:
					t.ident = tok.text
				}
			}
			if p.acceptKw("desc") {
				t.desc = true
			} else {
				p.acceptKw("asc")
			}
			s.order = append(s.order, t)
			if !p.acceptOp(",") {
				break
			}
		}
	}
	if p.acceptKw("limit") {
		s.limit = p.integer()
		if p.acceptKw("offset") {
			s.offset = p.integer()
		}
	}
	return s
}

// Expression parsing: one function per precedence level.

func (p *parser) parseExpr() *expr {
	l := p.parseAnd()
	for p.acceptKw("or") {
		l = &expr{kind: eBin, op: "or", l: l, r: p.parseAnd()}
	}
	return l
}

func (p *parser) parseAnd() *expr {
	l := p.parseNot()
	for p.acceptKw("and") {
		l = &expr{kind: eBin, op: "and", l: l, r: p.parseNot()}
	}
	return l
}

func (p *parser) parseNot() *expr {
	if p.acceptKw("not") {
		return &expr{kind: eNot, l: p.parseNot()}
	}
	return p.parseEq()
}

func (p *parser) parseEq() *expr {
	l := p.parseRel()
	for {
		t := p.peek()
		switch {
		case t.kind == tOp && (t.text == "=" || t.text == "==" || t.text == "!=" || t.text == "<>"):
			p.pos++
			op := t.text
			if op == "==" {
				op = "="
			} else if op == "<>" {
				op = "!="
			}
			l = &expr{kind: eBin, op: op, l: l, r: p.parseRel()}
		case t.isKw("is"):
			p.pos++
			neg := p.acceptKw("not")
			p.expectKw("null")
			l = &expr{kind: eIsNull, l: l, neg: neg}
		case t.isKw("like"):
			p.pos++
			l = &expr{kind: eLike, l: l, r: p.parseRel()}
		case t.isKw("not") && p.peekAt(1).isKw("like"):
			p.pos += 2
			l = &expr{kind: eLike, l: l, r: p.parseRel(), neg: true}
		default:
			return l
		}
	}
}

func (p *parser) parseRel() *expr {
	l := p.parseAdd()
	for {
		t := p.peek()
		if t.kind == tOp && (t.text == "<" || t.text == "<=" || t.text == ">" || t.text == ">=") {
			p.pos++
			l = &expr{kind: eBin, op: t.text, l: l, r: p.parseAdd()}
		} else {
			return l
		}
	}
}

func (p *parser) parseAdd() *expr {
	l := p.parseMul()
	for {
		t := p.peek()
		if t.kind == tOp && (t.text == "+" || t.text == "-") {
			p.pos++
			l = &expr{kind: eBin, op: t.text, l: l, r: p.parseMul()}
		} else {
			return l
		}
	}
}

func (p *parser) parseMul() *expr {
	l := p.parseUnary()
	for {
		t := p.peek()
		if t.kind == tOp && (t.text == "*" || t.text == "/" || t.text == "%") {
			p.pos++
			l = &expr{kind: eBin, op: t.text, l: l, r: p.parseUnary()}
		} else {
			return l
		}
	}
}

func (p *parser) parseUnary() *expr {
	if p.acceptOp("-") {
		return &expr{kind: eNeg, l: p.parseUnary()}
	}
	return p.parsePrimary()
}

func isAggName(s string) bool {
	switch s {
	case "count", "sum", "min", "max", "avg":
		return true
	}
	return false
}

func (p *parser) parsePrimary() *expr {
	t := p.next()
	switch {
	case t.kind == tInt:
		return &expr{kind: eInt, ival: t.ival}
	case t.kind == tString:
		return &expr{kind: eStr, sval: t.text}
	case t.isKw("null"):
		return &expr{kind: eNull}
	case t.isOp("("):
		e := p.parseExpr()
		p.expectOp(")")
		return e
	case t.kind == tIdent:
		if isAggName(t.text) && p.peek().isOp("(") {
			p.pos++
			e := &expr{kind: eAgg, fn: t.text}
			if t.text == "count" && p.acceptOp("*") {
				e.star = true
			} else {
				e.arg = p.parseExpr()
			}
			p.expectOp(")")
			return e
		}
		if p.acceptOp(".") {
			return &expr{kind: eCol, qual: t.text, name: p.ident()}
		}
		return &expr{kind: eCol, name: t.text}
	}
	syntaxErr("unexpected token in expression")
	return nil
}
