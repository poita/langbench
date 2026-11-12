package syntax

import (
	"fmt"
)

// SyntaxError describes why a statement could not be parsed.
type SyntaxError struct {
	Msg string
}

func (e *SyntaxError) Error() string { return "syntax error: " + e.Msg }

// Parsed is the outcome of parsing one statement of a script: either a
// statement or the error that made it unparseable.
type Parsed struct {
	Stmt Stmt
	Err  error
}

// ParseScript lexes src, splits it into statements and parses each one.
// A statement that fails to parse yields a Parsed with Err set; parsing
// continues with the next statement.
func ParseScript(src string) []Parsed {
	var out []Parsed
	for _, toks := range SplitStatements(Lex(src)) {
		stmt, err := ParseTokens(toks)
		out = append(out, Parsed{Stmt: stmt, Err: err})
	}
	return out
}

// ParseTokens parses the tokens of exactly one statement (without its
// terminating ';').
func ParseTokens(toks []Token) (stmt Stmt, err error) {
	for _, t := range toks {
		if t.Kind == TokInvalid || t.Kind == TokUnterminated {
			return nil, &SyntaxError{"invalid token"}
		}
	}
	p := &parser{toks: toks}
	defer func() {
		if r := recover(); r != nil {
			se, ok := r.(*SyntaxError)
			if !ok {
				panic(r)
			}
			stmt, err = nil, se
		}
	}()
	stmt = p.parseStatement()
	if p.peek().Kind != TokEOF {
		p.fail("unexpected token %q", p.peek().Text)
	}
	return stmt, nil
}

type parser struct {
	toks []Token
	pos  int
}

func (p *parser) fail(format string, args ...any) {
	panic(&SyntaxError{fmt.Sprintf(format, args...)})
}

func (p *parser) peek() Token { return p.peekAt(0) }

func (p *parser) peekAt(n int) Token {
	if p.pos+n < len(p.toks) {
		return p.toks[p.pos+n]
	}
	return Token{Kind: TokEOF}
}

func (p *parser) next() Token {
	t := p.peek()
	if t.Kind != TokEOF {
		p.pos++
	}
	return t
}

func (p *parser) isKw(k string) bool {
	t := p.peek()
	return t.Kind == TokKeyword && t.Text == k
}

func (p *parser) acceptKw(k string) bool {
	if p.isKw(k) {
		p.pos++
		return true
	}
	return false
}

func (p *parser) expectKw(k string) {
	if !p.acceptKw(k) {
		p.fail("expected %s", k)
	}
}

func (p *parser) isPunct(s string) bool {
	t := p.peek()
	return t.Kind == TokPunct && t.Text == s
}

func (p *parser) acceptPunct(s string) bool {
	if p.isPunct(s) {
		p.pos++
		return true
	}
	return false
}

func (p *parser) expectPunct(s string) {
	if !p.acceptPunct(s) {
		p.fail("expected %q", s)
	}
}

// name consumes a non-reserved identifier.
func (p *parser) name() string {
	t := p.peek()
	if t.Kind != TokIdent {
		p.fail("expected a name")
	}
	p.pos++
	return t.Text
}

func (p *parser) parseStatement() Stmt {
	t := p.peek()
	if t.Kind != TokKeyword {
		p.fail("expected a statement")
	}
	switch t.Text {
	case "CREATE":
		return p.parseCreate()
	case "INSERT":
		return p.parseInsert()
	case "DELETE":
		return p.parseDelete()
	case "UPDATE":
		return p.parseUpdate()
	case "SELECT":
		return p.parseSelect()
	}
	p.fail("unsupported statement %s", t.Text)
	return nil
}

func (p *parser) parseCreate() Stmt {
	p.expectKw("CREATE")
	p.expectKw("TABLE")
	st := &CreateTable{Name: p.name()}
	p.expectPunct("(")
	for {
		col := ColumnDef{Name: p.name()}
		switch {
		case p.acceptKw("INTEGER"):
			col.Type = "INTEGER"
		case p.acceptKw("TEXT"):
			col.Type = "TEXT"
		default:
			p.fail("expected INTEGER or TEXT")
		}
		st.Columns = append(st.Columns, col)
		if !p.acceptPunct(",") {
			break
		}
	}
	p.expectPunct(")")
	return st
}

func (p *parser) parseInsert() Stmt {
	p.expectKw("INSERT")
	p.expectKw("INTO")
	st := &Insert{Table: p.name()}
	p.expectKw("VALUES")
	for {
		p.expectPunct("(")
		var row []*Expr
		for {
			row = append(row, p.parseExpr())
			if !p.acceptPunct(",") {
				break
			}
		}
		p.expectPunct(")")
		st.Rows = append(st.Rows, row)
		if !p.acceptPunct(",") {
			break
		}
	}
	return st
}

func (p *parser) parseDelete() Stmt {
	p.expectKw("DELETE")
	p.expectKw("FROM")
	st := &Delete{Table: p.name()}
	if p.acceptKw("WHERE") {
		st.Where = p.parseExpr()
	}
	return st
}

func (p *parser) parseUpdate() Stmt {
	p.expectKw("UPDATE")
	st := &Update{Table: p.name()}
	p.expectKw("SET")
	for {
		col := p.name()
		p.expectPunct("=")
		st.Set = append(st.Set, Assignment{Column: col, Value: p.parseExpr()})
		if !p.acceptPunct(",") {
			break
		}
	}
	if p.acceptKw("WHERE") {
		st.Where = p.parseExpr()
	}
	return st
}

func (p *parser) parseSelect() Stmt {
	p.expectKw("SELECT")
	st := &Select{}
	for {
		st.Items = append(st.Items, p.parseItem())
		if !p.acceptPunct(",") {
			break
		}
	}
	if p.acceptKw("FROM") {
		st.From = append(st.From, p.parseTableRef())
		switch {
		case p.acceptPunct(","):
			st.From = append(st.From, p.parseTableRef())
		case p.isKw("INNER") || p.isKw("JOIN"):
			if p.acceptKw("INNER") && !p.isKw("JOIN") {
				p.fail("expected JOIN")
			}
			p.expectKw("JOIN")
			st.From = append(st.From, p.parseTableRef())
			p.expectKw("ON")
			st.On = p.parseExpr()
		}
	}
	if p.acceptKw("WHERE") {
		st.Where = p.parseExpr()
	}
	if p.acceptKw("GROUP") {
		p.expectKw("BY")
		for {
			st.GroupBy = append(st.GroupBy, p.parseColumnRef())
			if !p.acceptPunct(",") {
				break
			}
		}
		if p.acceptKw("HAVING") {
			st.Having = p.parseExpr()
		}
	}
	if p.acceptKw("ORDER") {
		p.expectKw("BY")
		for {
			term := OrderTerm{Expr: p.parseExpr()}
			if p.acceptKw("DESC") {
				term.Desc = true
			} else {
				p.acceptKw("ASC")
			}
			st.OrderBy = append(st.OrderBy, term)
			if !p.acceptPunct(",") {
				break
			}
		}
	}
	if p.acceptKw("LIMIT") {
		n := p.integer()
		st.Limit = &n
		if p.acceptKw("OFFSET") {
			m := p.integer()
			st.Offset = &m
		}
	}
	return st
}

func (p *parser) integer() int64 {
	t := p.peek()
	if t.Kind != TokInt {
		p.fail("expected an integer")
	}
	p.pos++
	return t.Int
}

func (p *parser) parseItem() SelectItem {
	if p.acceptPunct("*") {
		return SelectItem{Star: true}
	}
	item := SelectItem{Expr: p.parseExpr()}
	if p.acceptKw("AS") {
		item.Alias = p.name()
	} else if p.peek().Kind == TokIdent {
		item.Alias = p.name()
	}
	return item
}

func (p *parser) parseTableRef() TableRef {
	ref := TableRef{Name: p.name()}
	if p.acceptKw("AS") {
		ref.Alias = p.name()
	} else if p.peek().Kind == TokIdent {
		ref.Alias = p.name()
	}
	return ref
}

func (p *parser) parseColumnRef() *Expr {
	first := p.name()
	if p.acceptPunct(".") {
		return &Expr{Kind: ExprColumn, Qual: first, Name: p.name()}
	}
	return &Expr{Kind: ExprColumn, Name: first}
}

// Expression parsing, lowest to highest precedence.

func (p *parser) parseExpr() *Expr {
	l := p.parseAnd()
	for p.acceptKw("OR") {
		l = &Expr{Kind: ExprBinary, Op: "OR", Left: l, Right: p.parseAnd()}
	}
	return l
}

func (p *parser) parseAnd() *Expr {
	l := p.parseNot()
	for p.acceptKw("AND") {
		l = &Expr{Kind: ExprBinary, Op: "AND", Left: l, Right: p.parseNot()}
	}
	return l
}

func (p *parser) parseNot() *Expr {
	if p.acceptKw("NOT") {
		return &Expr{Kind: ExprNot, Left: p.parseNot()}
	}
	return p.parseEq()
}

func (p *parser) parseEq() *Expr {
	l := p.parseRel()
	for {
		t := p.peek()
		switch {
		case t.Kind == TokPunct && (t.Text == "=" || t.Text == "==" || t.Text == "!=" || t.Text == "<>"):
			p.pos++
			op := t.Text
			if op == "==" {
				op = "="
			} else if op == "<>" {
				op = "!="
			}
			l = &Expr{Kind: ExprBinary, Op: op, Left: l, Right: p.parseRel()}
		case p.acceptKw("IS"):
			neg := p.acceptKw("NOT")
			p.expectKw("NULL")
			l = &Expr{Kind: ExprIsNull, Negated: neg, Left: l}
		case p.acceptKw("LIKE"):
			l = &Expr{Kind: ExprLike, Left: l, Right: p.parseRel()}
		case p.isKw("NOT"):
			p.pos++
			p.expectKw("LIKE")
			like := &Expr{Kind: ExprLike, Left: l, Right: p.parseRel()}
			l = &Expr{Kind: ExprNot, Left: like}
		default:
			return l
		}
	}
}

func (p *parser) parseRel() *Expr {
	l := p.parseAdd()
	for {
		t := p.peek()
		if t.Kind == TokPunct && (t.Text == "<" || t.Text == "<=" || t.Text == ">" || t.Text == ">=") {
			p.pos++
			l = &Expr{Kind: ExprBinary, Op: t.Text, Left: l, Right: p.parseAdd()}
			continue
		}
		return l
	}
}

func (p *parser) parseAdd() *Expr {
	l := p.parseMul()
	for {
		t := p.peek()
		if t.Kind == TokPunct && (t.Text == "+" || t.Text == "-") {
			p.pos++
			l = &Expr{Kind: ExprBinary, Op: t.Text, Left: l, Right: p.parseMul()}
			continue
		}
		return l
	}
}

func (p *parser) parseMul() *Expr {
	l := p.parseUnary()
	for {
		t := p.peek()
		if t.Kind == TokPunct && (t.Text == "*" || t.Text == "/" || t.Text == "%") {
			p.pos++
			l = &Expr{Kind: ExprBinary, Op: t.Text, Left: l, Right: p.parseUnary()}
			continue
		}
		return l
	}
}

func (p *parser) parseUnary() *Expr {
	if p.acceptPunct("-") {
		return &Expr{Kind: ExprNeg, Left: p.parseUnary()}
	}
	return p.parsePrimary()
}

var aggregateNames = map[string]string{
	"count": "COUNT", "sum": "SUM", "min": "MIN", "max": "MAX", "avg": "AVG",
}

func (p *parser) parsePrimary() *Expr {
	t := p.peek()
	switch t.Kind {
	case TokInt:
		p.pos++
		return &Expr{Kind: ExprInt, Int: t.Int}
	case TokString:
		p.pos++
		return &Expr{Kind: ExprString, Str: t.Text}
	case TokKeyword:
		if t.Text == "NULL" {
			p.pos++
			return &Expr{Kind: ExprNull}
		}
	case TokPunct:
		if t.Text == "(" {
			p.pos++
			e := p.parseExpr()
			p.expectPunct(")")
			return &Expr{Kind: ExprParen, Left: e}
		}
	case TokIdent:
		next := p.peekAt(1)
		if next.Kind == TokPunct && next.Text == "(" {
			fn, ok := aggregateNames[t.Text]
			if !ok {
				p.fail("unknown function %s", t.Text)
			}
			p.pos += 2
			agg := &Expr{Kind: ExprAgg, Func: fn}
			if fn == "COUNT" && p.acceptPunct("*") {
				// COUNT(*): no argument
			} else {
				agg.Left = p.parseExpr()
			}
			p.expectPunct(")")
			return agg
		}
		return p.parseColumnRef()
	}
	p.fail("unexpected %q in expression", t.Text)
	return nil
}
