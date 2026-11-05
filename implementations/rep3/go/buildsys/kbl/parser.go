package kbl

import "strings"

var reservedWords = map[string]bool{
	"abort": true, "after": true, "cmd": true, "cost": true, "default": true,
	"depfile": true, "each": true, "elsewhen": true, "false": true, "in": true,
	"include": true, "let": true, "otherwise": true, "out": true, "phony": true,
	"rule": true, "set": true, "step": true, "true": true, "use": true, "when": true,
}

// parseBail is the panic value used to abandon the logical line being parsed.
type parseBail struct{}

func bail() { panic(parseBail{}) }

// exprParser parses an expression (and the argument lists around it) from a
// token slice.
type exprParser struct {
	toks []token
	pos  int
}

func (p *exprParser) eof() bool { return p.pos >= len(p.toks) }

func (p *exprParser) peek() *token {
	if p.eof() {
		return nil
	}
	return &p.toks[p.pos]
}

func (p *exprParser) next() *token {
	if p.eof() {
		bail()
	}
	t := &p.toks[p.pos]
	p.pos++
	return t
}

func (p *exprParser) isPunct(s string) bool {
	t := p.peek()
	return t != nil && t.kind == tkPunct && t.text == s
}

func (p *exprParser) isOp(s string) bool {
	t := p.peek()
	return t != nil && t.kind == tkOp && t.text == s
}

func (p *exprParser) expectPunct(s string) {
	if !p.isPunct(s) {
		bail()
	}
	p.pos++
}

// ident consumes a non-reserved identifier.
func (p *exprParser) ident() string {
	t := p.next()
	if t.kind != tkIdent || reservedWords[t.text] {
		bail()
	}
	return t.text
}

// anyIdent consumes an identifier, reserved or not (call/command/rule names).
func (p *exprParser) anyIdent() string {
	t := p.next()
	if t.kind != tkIdent {
		bail()
	}
	return t.text
}

func (p *exprParser) expectEnd() {
	if !p.eof() {
		bail()
	}
}

// parseExpr parses a complete expression.
func (p *exprParser) parseExpr() Expr {
	e := p.parseBinary(0)
	for p.isOp("|>") {
		p.pos++
		name := p.anyIdent()
		args := []Expr{e}
		if p.isPunct("(") {
			p.pos++
			args = append(args, p.exprList(")")...)
		}
		e = &CallExpr{Name: name, Fn: builtins[name], Args: args}
	}
	return e
}

// exprList parses `[expr {, expr} [,]] close`, the opening bracket having been
// consumed.
func (p *exprParser) exprList(close string) []Expr {
	var out []Expr
	for {
		if p.isPunct(close) {
			p.pos++
			return out
		}
		out = append(out, p.parseExpr())
		if p.isPunct(",") {
			p.pos++
			continue
		}
		p.expectPunct(close)
		return out
	}
}

var binaryLevels = [][]string{
	{"||"},
	{"&&"},
	{"==", "!=", "<", "<=", ">", ">="},
	{"++"},
	{"~"},
	{"+", "-"},
	{"*", "/", "%"},
}

func (p *exprParser) parseBinary(level int) Expr {
	if level == len(binaryLevels) {
		return p.parseUnary()
	}
	l := p.parseBinary(level + 1)
	for {
		t := p.peek()
		if t == nil || t.kind != tkOp {
			return l
		}
		match := false
		for _, op := range binaryLevels[level] {
			if t.text == op {
				match = true
				break
			}
		}
		if !match {
			return l
		}
		p.pos++
		r := p.parseBinary(level + 1)
		l = &BinaryExpr{Op: t.text, L: l, R: r}
	}
}

func (p *exprParser) parseUnary() Expr {
	if t := p.peek(); t != nil && t.kind == tkOp && (t.text == "!" || t.text == "-") {
		p.pos++
		return &UnaryExpr{Op: t.text, X: p.parseUnary()}
	}
	return p.parsePostfix()
}

func (p *exprParser) parsePostfix() Expr {
	e := p.parsePrimary()
	for {
		switch {
		case p.isPunct("["):
			p.pos++
			i := p.parseExpr()
			p.expectPunct("]")
			e = &IndexExpr{X: e, I: i}
		case p.isPunct("("):
			bail() // a call applies only to a bare identifier
		default:
			return e
		}
	}
}

func (p *exprParser) parsePrimary() Expr {
	t := p.next()
	switch t.kind {
	case tkInt:
		return &LitExpr{Val: intVal(t.ival)}
	case tkStr:
		return parseStringLiteral(t.text)
	case tkIdent:
		if p.isPunct("(") {
			p.pos++
			return &CallExpr{Name: t.text, Fn: builtins[t.text], Args: p.exprList(")")}
		}
		switch {
		case t.text == "true":
			return &LitExpr{Val: boolVal(true)}
		case t.text == "false":
			return &LitExpr{Val: boolVal(false)}
		case reservedWords[t.text]:
			bail()
		}
		return &VarExpr{Name: t.text}
	case tkPunct:
		switch t.text {
		case "(":
			e := p.parseExpr()
			p.expectPunct(")")
			return e
		case "[":
			return &ListExpr{Elems: p.exprList("]")}
		}
	}
	bail()
	return nil
}

// parseStringLiteral turns a complete literal token (quotes included) into an
// expression. It bails on bad escapes, stray braces and bad interpolations.
func parseStringLiteral(raw string) Expr {
	if raw[0] == '\'' {
		return &LitExpr{Val: strVal(strings.ReplaceAll(raw[1:len(raw)-1], "''", "'"))}
	}
	c := raw[1 : len(raw)-1]
	var parts []TemplatePart
	var cur []byte
	flush := func() {
		if len(cur) > 0 {
			parts = append(parts, TemplatePart{Lit: string(cur)})
			cur = cur[:0]
		}
	}
	hasInterp := false
	for i := 0; i < len(c); {
		switch ch := c[i]; ch {
		case '\\':
			if i+1 >= len(c) {
				bail()
			}
			switch c[i+1] {
			case '\\', '"':
				cur = append(cur, c[i+1])
			case 'n':
				cur = append(cur, '\n')
			case 't':
				cur = append(cur, '\t')
			case 'r':
				cur = append(cur, '\r')
			case '0':
				cur = append(cur, 0)
			default:
				bail()
			}
			i += 2
		case '{':
			if i+1 < len(c) && c[i+1] == '{' {
				cur = append(cur, '{')
				i += 2
				continue
			}
			j, depth := i+1, 1
			for depth > 0 {
				if j >= len(c) {
					bail()
				}
				switch c[j] {
				case '"', '\'':
					e, ok := skipLiteral(c, j)
					if !ok {
						bail()
					}
					j = e
					continue
				case '{':
					depth++
				case '}':
					depth--
				}
				j++
			}
			toks, ok := tokenize(c[i+1 : j-1])
			if !ok || len(toks) == 0 {
				bail()
			}
			sub := &exprParser{toks: toks}
			e := sub.parseExpr()
			sub.expectEnd()
			flush()
			parts = append(parts, TemplatePart{Expr: e})
			hasInterp = true
			i = j
		case '}':
			if i+1 < len(c) && c[i+1] == '}' {
				cur = append(cur, '}')
				i += 2
				continue
			}
			bail()
		default:
			cur = append(cur, ch)
			i++
		}
	}
	if !hasInterp {
		return &LitExpr{Val: strVal(string(cur))}
	}
	flush()
	return &TemplateExpr{Parts: parts}
}

// ---- statements and blocks ----

type frameKind uint8

const (
	frameRoot frameKind = iota
	frameWhen
	frameEach
	frameRule
	frameStep
)

type frame struct {
	kind   frameKind
	line   int
	body   *[]Stmt
	when   *WhenStmt
	inElse bool
	step   *StepStmt
}

type fileParser struct {
	stack []*frame
}

func (fp *fileParser) top() *frame { return fp.stack[len(fp.stack)-1] }

// Parse lexes and parses a build file. On a syntax error it returns a
// *SyntaxError carrying the 1-based line number of the offending logical line
// (or of the innermost unterminated block header).
func Parse(src string) (*File, error) {
	lines, err := lexFile(src)
	if err != nil {
		return nil, err
	}
	f := &File{}
	fp := &fileParser{stack: []*frame{{kind: frameRoot, body: &f.Body}}}
	for _, ln := range lines {
		if err := fp.line(ln); err != nil {
			return nil, err
		}
	}
	if len(fp.stack) > 1 {
		return nil, &SyntaxError{fp.top().line}
	}
	return f, nil
}

func (fp *fileParser) line(ln logicalLine) (err error) {
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(parseBail); ok {
				err = &SyntaxError{ln.no}
				return
			}
			panic(r)
		}
	}()
	toks := ln.toks
	first, last := toks[0], toks[len(toks)-1]
	switch {
	case first.kind == tkPunct && first.text == "}":
		fp.terminator(ln)
	case last.kind == tkPunct && last.text == "{":
		fp.header(ln)
	case fp.top().kind == frameStep:
		fp.top().step.Fields = append(fp.top().step.Fields, parseStepField(toks))
	default:
		*fp.top().body = append(*fp.top().body, parseSimpleStmt(toks))
	}
	return nil
}

func (fp *fileParser) terminator(ln logicalLine) {
	toks := ln.toks
	top := fp.top()
	if top.kind == frameRoot {
		bail()
	}
	if len(toks) == 1 {
		fp.stack = fp.stack[:len(fp.stack)-1]
		return
	}
	last := toks[len(toks)-1]
	if toks[1].kind != tkIdent || last.kind != tkPunct || last.text != "{" ||
		top.kind != frameWhen || top.inElse {
		bail()
	}
	switch toks[1].text {
	case "elsewhen":
		if len(toks) < 4 {
			bail()
		}
		p := &exprParser{toks: toks[2 : len(toks)-1]}
		cond := p.parseExpr()
		p.expectEnd()
		br := &Branch{Cond: cond}
		top.when.Branches = append(top.when.Branches, br)
		top.body = &br.Body
		top.line = ln.no
	case "otherwise":
		if len(toks) != 3 {
			bail()
		}
		br := &Branch{}
		top.when.Else = br
		top.inElse = true
		top.body = &br.Body
		top.line = ln.no
	default:
		bail()
	}
}

func (fp *fileParser) header(ln logicalLine) {
	top := fp.top()
	if top.kind == frameStep {
		bail()
	}
	h := ln.toks[:len(ln.toks)-1]
	if len(h) == 0 || h[0].kind != tkIdent {
		bail()
	}
	p := &exprParser{toks: h, pos: 1}
	var f *frame
	switch h[0].text {
	case "step":
		p.expectEnd()
		st := &StepStmt{}
		*top.body = append(*top.body, st)
		f = &frame{kind: frameStep, step: st}
	case "when":
		cond := p.parseExpr()
		p.expectEnd()
		br := &Branch{Cond: cond}
		w := &WhenStmt{Branches: []*Branch{br}}
		*top.body = append(*top.body, w)
		f = &frame{kind: frameWhen, when: w, body: &br.Body}
	case "each":
		st := &EachStmt{}
		st.Name = p.ident()
		if p.isPunct(",") {
			p.pos++
			st.Index, st.Name = st.Name, p.ident()
			if st.Index == st.Name {
				bail()
			}
		}
		if t := p.next(); t.kind != tkIdent || t.text != "in" {
			bail()
		}
		st.X = p.parseExpr()
		p.expectEnd()
		*top.body = append(*top.body, st)
		f = &frame{kind: frameEach, body: &st.Body}
	case "rule":
		st := &RuleStmt{Name: p.ident()}
		p.expectPunct("(")
		seen := map[string]bool{}
		sawDefault := false
		for !p.isPunct(")") {
			par := Param{Name: p.ident()}
			if seen[par.Name] {
				bail()
			}
			seen[par.Name] = true
			if p.isPunct("=") {
				p.pos++
				par.Default = p.parseExpr()
				sawDefault = true
			} else if sawDefault {
				bail()
			}
			st.Params = append(st.Params, par)
			if p.isPunct(",") {
				p.pos++
			} else if !p.isPunct(")") {
				bail()
			}
		}
		p.pos++
		p.expectEnd()
		*top.body = append(*top.body, st)
		f = &frame{kind: frameRule, body: &st.Body}
	default:
		bail()
	}
	f.line = ln.no
	fp.stack = append(fp.stack, f)
}

func parseSimpleStmt(toks []token) Stmt {
	if toks[0].kind != tkIdent {
		bail()
	}
	p := &exprParser{toks: toks, pos: 1}
	switch toks[0].text {
	case "let", "set":
		name := p.ident()
		p.expectPunct("=")
		x := p.parseExpr()
		p.expectEnd()
		if toks[0].text == "let" {
			return &LetStmt{Name: name, X: x}
		}
		return &SetStmt{Name: name, X: x}
	case "include":
		x := p.parseExpr()
		p.expectEnd()
		return &IncludeStmt{X: x}
	case "abort":
		x := p.parseExpr()
		p.expectEnd()
		return &AbortStmt{X: x}
	case "default":
		x := p.parseExpr()
		p.expectEnd()
		return &DefaultStmt{X: x}
	case "phony":
		name := p.ident()
		p.expectPunct("=")
		x := p.parseExpr()
		p.expectEnd()
		return &PhonyStmt{Name: name, X: x}
	case "use":
		st := &UseStmt{Rule: p.anyIdent()}
		p.expectPunct("(")
		sawKw := false
		for !p.isPunct(")") {
			if p.eof() {
				bail()
			}
			arg := UseArg{}
			t, n := p.peek(), (*token)(nil)
			if p.pos+1 < len(toks) {
				n = &toks[p.pos+1]
			}
			if t.kind == tkIdent && !reservedWords[t.text] && n != nil && n.kind == tkPunct && n.text == "=" {
				arg.Name = t.text
				p.pos += 2
				sawKw = true
			} else if sawKw {
				bail()
			}
			arg.X = p.parseExpr()
			st.Args = append(st.Args, arg)
			if p.isPunct(",") {
				p.pos++
			} else if !p.isPunct(")") {
				bail()
			}
		}
		p.pos++
		p.expectEnd()
		return st
	}
	bail()
	return nil
}

func parseStepField(toks []token) StepField {
	if toks[0].kind != tkIdent {
		bail()
	}
	p := &exprParser{toks: toks, pos: 1}
	switch kind := toks[0].text; kind {
	case "out", "in", "after", "cost", "depfile":
		x := p.parseExpr()
		p.expectEnd()
		return StepField{Kind: kind, X: x}
	case "cmd":
		name := p.anyIdent()
		p.expectPunct("(")
		args := p.exprList(")")
		p.expectEnd()
		return StepField{Kind: "cmd", CmdName: name, Args: args}
	}
	bail()
	return StepField{}
}
