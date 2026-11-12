package kbl

// Parse lexes and parses a whole build file into statements. Errors are
// *ParseError values carrying the offending logical line's number.
func Parse(src string) ([]Stmt, error) {
	lines, err := Lex(src)
	if err != nil {
		return nil, err
	}
	return parseLines(lines)
}

var reserved = map[string]bool{
	"abort": true, "after": true, "cmd": true, "cost": true, "default": true,
	"depfile": true, "each": true, "elsewhen": true, "false": true, "in": true,
	"include": true, "let": true, "otherwise": true, "out": true, "phony": true,
	"rule": true, "set": true, "step": true, "true": true, "use": true, "when": true,
}

// IsReserved reports whether name is a reserved word.
func IsReserved(name string) bool { return reserved[name] }

type parseFail struct{}

func fail() { panic(parseFail{}) }

type blockKind uint8

const (
	blkRoot blockKind = iota
	blkWhen
	blkEach
	blkRule
	blkStep
)

type frame struct {
	kind blockKind
	line int
	body []Stmt

	// when
	when   When
	cond   Expr
	inElse bool
	// each / rule
	each Each
	rule Rule
	// step
	fields []StepField
}

func parseLines(lines []Line) (stmts []Stmt, err error) {
	cur := 0
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(parseFail); !ok {
				panic(r)
			}
			stmts, err = nil, &ParseError{Line: cur}
		}
	}()
	stack := []*frame{{kind: blkRoot}}
	top := func() *frame { return stack[len(stack)-1] }
	emit := func(s Stmt) { f := top(); f.body = append(f.body, s) }

	for _, l := range lines {
		cur = l.Num
		toks := l.Toks
		n := len(toks)
		f := top()
		switch {
		case isPunct(toks[0], "}"):
			if f.kind == blkRoot {
				fail()
			}
			switch {
			case n == 1:
				stack = stack[:len(stack)-1]
				emit(closeFrame(f))
			case isIdent(toks[1], "elsewhen") && isPunct(toks[n-1], "{"):
				if f.kind != blkWhen || f.inElse {
					fail()
				}
				ep := &exprParser{toks: toks[:n-1], pos: 2}
				cond := ep.expr()
				ep.done()
				f.when.Conds = append(f.when.Conds, f.cond)
				f.when.Bodies = append(f.when.Bodies, f.body)
				f.cond, f.body, f.line = cond, nil, l.Num
			case n == 3 && isIdent(toks[1], "otherwise") && isPunct(toks[2], "{"):
				if f.kind != blkWhen || f.inElse {
					fail()
				}
				f.when.Conds = append(f.when.Conds, f.cond)
				f.when.Bodies = append(f.when.Bodies, f.body)
				f.cond, f.body, f.inElse, f.line = nil, nil, true, l.Num
			default:
				fail()
			}
		case isPunct(toks[n-1], "{"):
			if f.kind == blkStep {
				fail()
			}
			stack = append(stack, parseHeader(toks, l.Num))
		case f.kind == blkStep:
			f.fields = append(f.fields, parseStepField(toks))
		default:
			emit(parseSimple(toks))
		}
	}
	if len(stack) > 1 {
		cur = top().line
		fail()
	}
	return stack[0].body, nil
}

func closeFrame(f *frame) Stmt {
	switch f.kind {
	case blkWhen:
		w := f.when
		if f.inElse {
			w.Else, w.HasElse = f.body, true
		} else {
			w.Conds = append(w.Conds, f.cond)
			w.Bodies = append(w.Bodies, f.body)
		}
		return w
	case blkEach:
		e := f.each
		e.Body = f.body
		return e
	case blkRule:
		r := f.rule
		r.Body = f.body
		return r
	default:
		return StepStmt{Fields: f.fields}
	}
}

func isPunct(t Token, s string) bool { return t.Kind == TokPunct && t.Text == s }
func isOp(t Token, s string) bool    { return t.Kind == TokOp && t.Text == s }
func isIdent(t Token, s string) bool { return t.Kind == TokIdent && t.Text == s }

func parseHeader(toks []Token, line int) *frame {
	n := len(toks)
	if toks[0].Kind != TokIdent {
		fail()
	}
	f := &frame{line: line}
	ep := &exprParser{toks: toks[:n-1], pos: 1}
	switch toks[0].Text {
	case "step":
		if n != 2 {
			fail()
		}
		f.kind = blkStep
	case "when":
		f.kind = blkWhen
		f.cond = ep.expr()
		ep.done()
	case "each":
		f.kind = blkEach
		first := ep.name()
		var second string
		if ep.acceptPunct(",") {
			second = ep.name()
		}
		if !ep.acceptIdent("in") {
			fail()
		}
		if second != "" {
			if first == second {
				fail()
			}
			f.each.Index, f.each.Name = first, second
		} else {
			f.each.Name = first
		}
		f.each.X = ep.expr()
		ep.done()
	case "rule":
		f.kind = blkRule
		f.rule.Name = ep.name()
		if !ep.acceptPunct("(") {
			fail()
		}
		seen := map[string]bool{}
		sawDefault := false
		for !ep.acceptPunct(")") {
			if len(f.rule.Params) > 0 && !ep.acceptPunct(",") {
				fail()
			}
			if ep.acceptPunct(")") {
				break
			}
			p := Param{Name: ep.name()}
			if seen[p.Name] {
				fail()
			}
			seen[p.Name] = true
			if ep.acceptPunct("=") {
				p.Default = ep.expr()
				sawDefault = true
			} else if sawDefault {
				fail()
			}
			f.rule.Params = append(f.rule.Params, p)
		}
		ep.done()
	default:
		fail()
	}
	return f
}

func parseSimple(toks []Token) Stmt {
	if toks[0].Kind != TokIdent {
		fail()
	}
	ep := &exprParser{toks: toks, pos: 1}
	switch toks[0].Text {
	case "let", "set", "phony":
		name := ep.name()
		if !ep.acceptPunct("=") {
			fail()
		}
		x := ep.expr()
		ep.done()
		switch toks[0].Text {
		case "let":
			return Let{Name: name, X: x}
		case "set":
			return Set{Name: name, X: x}
		}
		return Phony{Name: name, X: x}
	case "include", "abort", "default":
		x := ep.expr()
		ep.done()
		switch toks[0].Text {
		case "include":
			return Include{X: x}
		case "abort":
			return Abort{X: x}
		}
		return Default{X: x}
	case "use":
		if ep.pos >= len(toks) || toks[ep.pos].Kind != TokIdent {
			fail()
		}
		u := Use{Rule: toks[ep.pos].Text}
		ep.pos++
		if !ep.acceptPunct("(") {
			fail()
		}
		sawKw := false
		for !ep.acceptPunct(")") {
			if len(u.Args) > 0 && !ep.acceptPunct(",") {
				fail()
			}
			if ep.acceptPunct(")") {
				break
			}
			if ep.pos+1 < len(toks) && toks[ep.pos].Kind == TokIdent && !reserved[toks[ep.pos].Text] &&
				isPunct(toks[ep.pos+1], "=") {
				name := toks[ep.pos].Text
				ep.pos += 2
				u.Args = append(u.Args, UseArg{Name: name, X: ep.expr()})
				sawKw = true
			} else {
				if sawKw {
					fail()
				}
				u.Args = append(u.Args, UseArg{X: ep.expr()})
			}
		}
		ep.done()
		return u
	}
	fail()
	return nil
}

func parseStepField(toks []Token) StepField {
	if toks[0].Kind != TokIdent {
		fail()
	}
	ep := &exprParser{toks: toks, pos: 1}
	switch kind := toks[0].Text; kind {
	case "out", "in", "after", "cost", "depfile":
		x := ep.expr()
		ep.done()
		return StepField{Kind: kind, X: x}
	case "cmd":
		if ep.pos >= len(toks) || toks[ep.pos].Kind != TokIdent {
			fail()
		}
		name := toks[ep.pos].Text
		ep.pos++
		if !ep.acceptPunct("(") {
			fail()
		}
		args := ep.args()
		ep.done()
		return StepField{Kind: "cmd", Cmd: name, Args: args}
	}
	fail()
	return StepField{}
}

// exprParser is a precedence-climbing parser over a token slice.
type exprParser struct {
	toks []Token
	pos  int
}

func (p *exprParser) more() bool { return p.pos < len(p.toks) }

func (p *exprParser) peek() Token {
	if p.pos >= len(p.toks) {
		return Token{Kind: TokOp, Text: "\x00eof"}
	}
	return p.toks[p.pos]
}

func (p *exprParser) done() {
	if p.more() {
		fail()
	}
}

func (p *exprParser) acceptPunct(s string) bool {
	if p.more() && isPunct(p.toks[p.pos], s) {
		p.pos++
		return true
	}
	return false
}

func (p *exprParser) acceptIdent(s string) bool {
	if p.more() && isIdent(p.toks[p.pos], s) {
		p.pos++
		return true
	}
	return false
}

// name consumes a non-reserved identifier.
func (p *exprParser) name() string {
	if !p.more() || p.toks[p.pos].Kind != TokIdent || reserved[p.toks[p.pos].Text] {
		fail()
	}
	p.pos++
	return p.toks[p.pos-1].Text
}

// args parses `expr {, expr} [,] )` after the opening parenthesis.
func (p *exprParser) args() []Expr {
	var out []Expr
	if p.acceptPunct(")") {
		return out
	}
	for {
		out = append(out, p.expr())
		if p.acceptPunct(",") {
			if p.acceptPunct(")") {
				return out
			}
			continue
		}
		if !p.acceptPunct(")") {
			fail()
		}
		return out
	}
}

func (p *exprParser) expr() Expr {
	left := p.binary(2)
	for p.more() && isOp(p.toks[p.pos], "|>") {
		p.pos++
		if !p.more() || p.toks[p.pos].Kind != TokIdent {
			fail()
		}
		call := Call{Name: p.toks[p.pos].Text, Args: []Expr{left}}
		p.pos++
		if p.acceptPunct("(") {
			call.Args = append(call.Args, p.args()...)
		}
		left = call
	}
	return left
}

var levelOps = [...][]string{
	2: {"||"},
	3: {"&&"},
	4: {"==", "!=", "<", "<=", ">", ">="},
	5: {"++"},
	6: {"~"},
	7: {"+", "-"},
	8: {"*", "/", "%"},
}

func (p *exprParser) binary(level int) Expr {
	if level > 8 {
		return p.unary()
	}
	left := p.binary(level + 1)
	for {
		t := p.peek()
		if t.Kind != TokOp {
			return left
		}
		matched := false
		for _, op := range levelOps[level] {
			if t.Text == op {
				matched = true
				break
			}
		}
		if !matched {
			return left
		}
		p.pos++
		left = Binary{Op: t.Text, L: left, R: p.binary(level + 1)}
	}
}

func (p *exprParser) unary() Expr {
	t := p.peek()
	if isOp(t, "!") || isOp(t, "-") {
		p.pos++
		return Unary{Op: t.Text, X: p.unary()}
	}
	return p.postfix()
}

func (p *exprParser) postfix() Expr {
	x := p.primary()
	for {
		switch {
		case p.acceptPunct("("):
			fail() // calls apply only to identifiers, handled in primary
		case p.acceptPunct("["):
			i := p.expr()
			if !p.acceptPunct("]") {
				fail()
			}
			x = Index{X: x, I: i}
		default:
			return x
		}
	}
}

func (p *exprParser) primary() Expr {
	if !p.more() {
		fail()
	}
	t := p.toks[p.pos]
	p.pos++
	switch t.Kind {
	case TokInt:
		return IntLit{V: t.Int}
	case TokStr:
		return parseString(t)
	case TokIdent:
		if p.acceptPunct("(") {
			return Call{Name: t.Text, Args: p.args()}
		}
		switch t.Text {
		case "true":
			return BoolLit{V: true}
		case "false":
			return BoolLit{V: false}
		}
		if reserved[t.Text] {
			fail()
		}
		return VarRef{Name: t.Text}
	case TokPunct:
		switch t.Text {
		case "(":
			x := p.expr()
			if !p.acceptPunct(")") {
				fail()
			}
			return x
		case "[":
			var elems []Expr
			if p.acceptPunct("]") {
				return ListLit{Elems: elems}
			}
			for {
				elems = append(elems, p.expr())
				if p.acceptPunct(",") {
					if p.acceptPunct("]") {
						return ListLit{Elems: elems}
					}
					continue
				}
				if !p.acceptPunct("]") {
					fail()
				}
				return ListLit{Elems: elems}
			}
		}
	}
	fail()
	return nil
}

// parseString interprets a string-literal token.
func parseString(t Token) Expr {
	s := t.Text
	if !t.Double {
		var b []byte
		for i := 0; i < len(s); i++ {
			b = append(b, s[i])
			if s[i] == '\'' { // an escaped '' pair
				i++
			}
		}
		return StrLit{Parts: []StrPart{{Lit: string(b)}}}
	}
	var parts []StrPart
	var lit []byte
	flush := func() {
		if len(lit) > 0 {
			parts = append(parts, StrPart{Lit: string(lit)})
			lit = nil
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
			case '\\':
				lit = append(lit, '\\')
			case '"':
				lit = append(lit, '"')
			case 'n':
				lit = append(lit, '\n')
			case 't':
				lit = append(lit, '\t')
			case 'r':
				lit = append(lit, '\r')
			case '0':
				lit = append(lit, 0)
			default:
				fail()
			}
			i += 2
		case '{':
			if i+1 < len(s) && s[i+1] == '{' {
				lit = append(lit, '{')
				i += 2
				continue
			}
			end := skipInterp(s, i)
			if end < 0 {
				fail()
			}
			body := s[i+1 : end-1]
			toks, err := Tokenize(body)
			if err != nil || len(toks) == 0 {
				fail()
			}
			ep := &exprParser{toks: toks}
			x := ep.expr()
			ep.done()
			flush()
			parts = append(parts, StrPart{X: x})
			i = end
		case '}':
			if i+1 < len(s) && s[i+1] == '}' {
				lit = append(lit, '}')
				i += 2
				continue
			}
			fail()
		default:
			lit = append(lit, c)
			i++
		}
	}
	flush()
	if len(parts) == 0 {
		parts = []StrPart{{Lit: ""}}
	}
	return StrLit{Parts: parts}
}
