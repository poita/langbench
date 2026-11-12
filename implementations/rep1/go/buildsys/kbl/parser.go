package kbl

import "strings"

// parseFile lexes and parses a whole build file. The error, if any, is a
// *syntaxError carrying the reported line.
func parseFile(src string) ([]stmt, error) {
	lines, err := lexFile(src)
	if err != nil {
		return nil, err
	}
	p := &parser{lines: lines}
	stmts, term, err := p.parseStmts(ctxTop)
	if err != nil {
		return nil, err
	}
	if term != nil {
		return nil, &syntaxError{term.num}
	}
	return stmts, nil
}

type blockCtx uint8

const (
	ctxTop blockCtx = iota
	ctxPlain
	ctxWhen
	ctxStep
)

type parser struct {
	lines []logicalLine
	pos   int
}

func fail(line int) error { return &syntaxError{line} }

// parseStmts parses statements until a block terminator line or end of file.
// It returns the terminator line (not validated) or nil at end of file.
func (p *parser) parseStmts(ctx blockCtx) ([]stmt, *logicalLine, error) {
	var out []stmt
	for p.pos < len(p.lines) {
		l := &p.lines[p.pos]
		p.pos++
		toks := l.toks
		if toks[0].is("}") {
			return out, l, nil
		}
		var s stmt
		var err error
		switch {
		case ctx == ctxStep:
			if toks[len(toks)-1].is("{") {
				return nil, nil, fail(l.num)
			}
			s, err = parseStepField(toks)
		case toks[len(toks)-1].is("{"):
			s, err = p.parseHeader(l)
		default:
			s, err = parseSimple(toks)
		}
		if err != nil {
			if err == errSyntax {
				err = fail(l.num)
			}
			return nil, nil, err
		}
		out = append(out, s)
	}
	return out, nil, nil
}

// parseBlock parses the body of a plain block (each, rule, step) opened by the
// header on line hdr, consuming the closing "}".
func (p *parser) parseBlock(ctx blockCtx, hdr int) ([]stmt, error) {
	body, term, err := p.parseStmts(ctx)
	if err != nil {
		return nil, err
	}
	if term == nil {
		return nil, fail(hdr)
	}
	if len(term.toks) != 1 {
		return nil, fail(term.num)
	}
	return body, nil
}

func (p *parser) parseHeader(l *logicalLine) (stmt, error) {
	toks := l.toks
	if toks[0].kind != tIdent {
		return nil, fail(l.num)
	}
	switch toks[0].text {
	case "step":
		if len(toks) != 2 {
			return nil, fail(l.num)
		}
		body, err := p.parseBlock(ctxStep, l.num)
		if err != nil {
			return nil, err
		}
		fields := make([]stepField, len(body))
		for i, b := range body {
			fields[i] = b.(stepField)
		}
		return &stepStmt{fields}, nil
	case "when":
		return p.parseWhen(l)
	case "each":
		return p.parseEach(l)
	case "rule":
		return p.parseRule(l)
	}
	return nil, fail(l.num)
}

func (p *parser) parseWhen(l *logicalLine) (stmt, error) {
	w := &whenStmt{}
	cond, err := parseWhole(l.toks[1 : len(l.toks)-1])
	if err != nil {
		return nil, fail(l.num)
	}
	hdr := l.num
	for {
		body, term, err := p.parseStmts(ctxWhen)
		if err != nil {
			return nil, err
		}
		if term == nil {
			return nil, fail(hdr)
		}
		w.conds = append(w.conds, cond)
		w.bodies = append(w.bodies, body)
		tt := term.toks
		switch {
		case len(tt) == 1:
			return w, nil
		case tt[1].kind == tIdent && tt[1].text == "elsewhen" && len(tt) >= 4 && tt[len(tt)-1].is("{"):
			cond, err = parseWhole(tt[2 : len(tt)-1])
			if err != nil {
				return nil, fail(term.num)
			}
			hdr = term.num
		case len(tt) == 3 && tt[1].kind == tIdent && tt[1].text == "otherwise" && tt[2].is("{"):
			other, term2, err := p.parseStmts(ctxWhen)
			if err != nil {
				return nil, err
			}
			if term2 == nil {
				return nil, fail(term.num)
			}
			if len(term2.toks) != 1 {
				return nil, fail(term2.num)
			}
			w.other, w.hasOther = other, true
			return w, nil
		default:
			return nil, fail(term.num)
		}
	}
}

func (p *parser) parseEach(l *logicalLine) (stmt, error) {
	toks := l.toks[:len(l.toks)-1] // without "{"
	i := 1
	ident := func() (string, bool) {
		if i < len(toks) && toks[i].kind == tIdent && !reserved[toks[i].text] {
			i++
			return toks[i-1].text, true
		}
		return "", false
	}
	first, ok := ident()
	if !ok {
		return nil, fail(l.num)
	}
	e := &eachStmt{name: first}
	if i < len(toks) && toks[i].is(",") {
		i++
		second, ok := ident()
		if !ok || second == first {
			return nil, fail(l.num)
		}
		e.index, e.name = first, second
	}
	if i >= len(toks) || toks[i].kind != tIdent || toks[i].text != "in" {
		return nil, fail(l.num)
	}
	subject, err := parseWhole(toks[i+1:])
	if err != nil {
		return nil, fail(l.num)
	}
	e.subject = subject
	body, err := p.parseBlock(ctxPlain, l.num)
	if err != nil {
		return nil, err
	}
	e.body = body
	return e, nil
}

func (p *parser) parseRule(l *logicalLine) (stmt, error) {
	toks := l.toks[:len(l.toks)-1]
	if len(toks) < 4 || toks[1].kind != tIdent || reserved[toks[1].text] || !toks[2].is("(") {
		return nil, fail(l.num)
	}
	r := &ruleStmt{name: toks[1].text}
	ep := &exprParser{toks: toks, i: 3}
	seen := map[string]bool{}
	sawDefault := false
	for {
		if ep.peek().is(")") {
			ep.i++
			break
		}
		t := ep.next()
		if t.kind != tIdent || reserved[t.text] || seen[t.text] {
			return nil, fail(l.num)
		}
		seen[t.text] = true
		pm := param{name: t.text}
		if ep.peek().is("=") {
			ep.i++
			def, err := ep.parseExpr()
			if err != nil {
				return nil, fail(l.num)
			}
			pm.def = def
			sawDefault = true
		} else if sawDefault {
			return nil, fail(l.num)
		}
		r.params = append(r.params, pm)
		if ep.peek().is(",") {
			ep.i++
			continue
		}
		if ep.peek().is(")") {
			continue
		}
		return nil, fail(l.num)
	}
	if ep.i != len(toks) {
		return nil, fail(l.num)
	}
	body, err := p.parseBlock(ctxPlain, l.num)
	if err != nil {
		return nil, err
	}
	r.body = body
	return r, nil
}

// parseWhole parses toks as one complete expression.
func parseWhole(toks []token) (expr, error) {
	ep := &exprParser{toks: toks}
	e, err := ep.parseExpr()
	if err != nil {
		return nil, err
	}
	if ep.i != len(toks) {
		return nil, errSyntax
	}
	return e, nil
}

func identTok(t token) bool { return t.kind == tIdent && !reserved[t.text] }

func parseSimple(toks []token) (stmt, error) {
	if toks[0].kind != tIdent {
		return nil, errSyntax
	}
	switch kw := toks[0].text; kw {
	case "let", "set", "phony":
		if len(toks) < 4 || !identTok(toks[1]) || !toks[2].is("=") {
			return nil, errSyntax
		}
		e, err := parseWhole(toks[3:])
		if err != nil {
			return nil, err
		}
		switch kw {
		case "let":
			return &letStmt{toks[1].text, e}, nil
		case "set":
			return &setStmt{toks[1].text, e}, nil
		}
		return &phonyStmt{toks[1].text, e}, nil
	case "include", "abort", "default":
		e, err := parseWhole(toks[1:])
		if err != nil {
			return nil, err
		}
		switch kw {
		case "include":
			return &includeStmt{e}, nil
		case "abort":
			return &abortStmt{e}, nil
		}
		return &defaultStmt{e}, nil
	case "use":
		return parseUse(toks)
	}
	return nil, errSyntax
}

func parseUse(toks []token) (stmt, error) {
	if len(toks) < 4 || toks[1].kind != tIdent || !toks[2].is("(") || !toks[len(toks)-1].is(")") {
		return nil, errSyntax
	}
	u := &useStmt{rule: toks[1].text}
	ep := &exprParser{toks: toks[:len(toks)-1], i: 3}
	sawKw := false
	for ep.i < len(ep.toks) {
		var a useArg
		if identTok(ep.peek()) && ep.i+1 < len(ep.toks) && ep.toks[ep.i+1].is("=") {
			a.kw = ep.toks[ep.i].text
			ep.i += 2
			sawKw = true
		} else if sawKw {
			return nil, errSyntax
		}
		e, err := ep.parseExpr()
		if err != nil {
			return nil, err
		}
		a.e = e
		u.args = append(u.args, a)
		if ep.i == len(ep.toks) {
			break
		}
		if !ep.peek().is(",") {
			return nil, errSyntax
		}
		ep.i++
	}
	return u, nil
}

func parseStepField(toks []token) (stepField, error) {
	if toks[0].kind != tIdent {
		return stepField{}, errSyntax
	}
	switch kw := toks[0].text; kw {
	case "out", "in", "after", "cost", "depfile":
		e, err := parseWhole(toks[1:])
		if err != nil {
			return stepField{}, err
		}
		return stepField{kind: kw, e: e}, nil
	case "cmd":
		if len(toks) < 4 || toks[1].kind != tIdent || !toks[2].is("(") || !toks[len(toks)-1].is(")") {
			return stepField{}, errSyntax
		}
		f := stepField{kind: "cmd", cmd: toks[1].text}
		ep := &exprParser{toks: toks[:len(toks)-1], i: 3}
		args, err := ep.parseArgs(false)
		if err != nil {
			return stepField{}, err
		}
		f.args = args
		return f, nil
	}
	return stepField{}, errSyntax
}

// exprParser is a precedence-climbing parser over a token slice.
type exprParser struct {
	toks []token
	i    int
}

var eofTok = token{kind: tPunct, text: "\x00eof"}

func (p *exprParser) peek() token {
	if p.i < len(p.toks) {
		return p.toks[p.i]
	}
	return eofTok
}

func (p *exprParser) next() token {
	t := p.peek()
	if p.i < len(p.toks) {
		p.i++
	}
	return t
}

// parseArgs parses a comma-separated expression list (trailing comma allowed)
// up to the end of the token slice, or up to a closing ")" when closed is true
// (which it consumes).
func (p *exprParser) parseArgs(closed bool) ([]expr, error) {
	var args []expr
	for {
		if closed && p.peek().is(")") {
			p.i++
			return args, nil
		}
		if !closed && p.i == len(p.toks) {
			return args, nil
		}
		e, err := p.parseExpr()
		if err != nil {
			return nil, err
		}
		args = append(args, e)
		if p.peek().is(",") {
			p.i++
			continue
		}
		if closed {
			if !p.peek().is(")") {
				return nil, errSyntax
			}
			continue
		}
		if p.i != len(p.toks) {
			return nil, errSyntax
		}
	}
}

func (p *exprParser) parseExpr() (expr, error) { return p.parsePipe() }

func (p *exprParser) parsePipe() (expr, error) {
	x, err := p.parseOr()
	if err != nil {
		return nil, err
	}
	for p.peek().is("|>") {
		p.i++
		t := p.next()
		if t.kind != tIdent {
			return nil, errSyntax
		}
		c := &call{name: t.text, args: []expr{x}}
		if p.peek().is("(") {
			p.i++
			rest, err := p.parseArgs(true)
			if err != nil {
				return nil, err
			}
			c.args = append(c.args, rest...)
		}
		x = c
	}
	return x, nil
}

// binaryLevel parses one left-associative binary level.
func (p *exprParser) binaryLevel(ops []string, sub func() (expr, error)) (expr, error) {
	l, err := sub()
	if err != nil {
		return nil, err
	}
	for {
		t := p.peek()
		if t.kind != tOp {
			return l, nil
		}
		matched := false
		for _, op := range ops {
			if t.text == op {
				matched = true
				break
			}
		}
		if !matched {
			return l, nil
		}
		p.i++
		r, err := sub()
		if err != nil {
			return nil, err
		}
		l = &binary{op: t.text, l: l, r: r}
	}
}

func (p *exprParser) parseOr() (expr, error)  { return p.binaryLevel([]string{"||"}, p.parseAnd) }
func (p *exprParser) parseAnd() (expr, error) { return p.binaryLevel([]string{"&&"}, p.parseCmp) }
func (p *exprParser) parseCmp() (expr, error) {
	return p.binaryLevel([]string{"==", "!=", "<", "<=", ">", ">="}, p.parseCat)
}
func (p *exprParser) parseCat() (expr, error) { return p.binaryLevel([]string{"++"}, p.parseStr) }
func (p *exprParser) parseStr() (expr, error) { return p.binaryLevel([]string{"~"}, p.parseAdd) }
func (p *exprParser) parseAdd() (expr, error) {
	return p.binaryLevel([]string{"+", "-"}, p.parseMul)
}
func (p *exprParser) parseMul() (expr, error) {
	return p.binaryLevel([]string{"*", "/", "%"}, p.parseUnary)
}

func (p *exprParser) parseUnary() (expr, error) {
	if t := p.peek(); t.is("!") || t.is("-") {
		p.i++
		x, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		return &unary{op: t.text, x: x}, nil
	}
	return p.parsePostfix()
}

func (p *exprParser) parsePostfix() (expr, error) {
	x, err := p.parsePrimary()
	if err != nil {
		return nil, err
	}
	for {
		switch {
		case p.peek().is("["):
			p.i++
			ix, err := p.parseExpr()
			if err != nil {
				return nil, err
			}
			if !p.next().is("]") {
				return nil, errSyntax
			}
			x = &index{x: x, i: ix}
		case p.peek().is("("):
			// A call is only legal directly on an identifier, which
			// parsePrimary has already consumed.
			return nil, errSyntax
		default:
			return x, nil
		}
	}
}

func (p *exprParser) parsePrimary() (expr, error) {
	t := p.next()
	switch t.kind {
	case tInt:
		return &intLit{t.num}, nil
	case tStr:
		return parseStringLit(t.text)
	case tIdent:
		if p.peek().is("(") {
			p.i++
			args, err := p.parseArgs(true)
			if err != nil {
				return nil, err
			}
			return &call{name: t.text, args: args}, nil
		}
		switch t.text {
		case "true":
			return &boolLit{true}, nil
		case "false":
			return &boolLit{false}, nil
		}
		if reserved[t.text] {
			return nil, errSyntax
		}
		return &varRef{t.text}, nil
	case tPunct:
		switch t.text {
		case "(":
			e, err := p.parseExpr()
			if err != nil {
				return nil, err
			}
			if !p.next().is(")") {
				return nil, errSyntax
			}
			return e, nil
		case "[":
			var elems []expr
			for {
				if p.peek().is("]") {
					p.i++
					return &list{elems}, nil
				}
				e, err := p.parseExpr()
				if err != nil {
					return nil, err
				}
				elems = append(elems, e)
				if p.peek().is(",") {
					p.i++
					continue
				}
				if !p.peek().is("]") {
					return nil, errSyntax
				}
			}
		}
	}
	return nil, errSyntax
}

// parseStringLit parses a raw string token (quotes included).
func parseStringLit(raw string) (expr, error) {
	if raw[0] == '\'' {
		return &strLit{parts: []strPart{{lit: strings.ReplaceAll(raw[1:len(raw)-1], "''", "'")}}}, nil
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
				return nil, errSyntax
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
				return nil, errSyntax
			}
			i += 2
		case '{':
			if i+1 < len(s) && s[i+1] == '{' {
				lit.WriteByte('{')
				i += 2
				continue
			}
			end := skipRegion(s, i+1)
			if end < 0 {
				return nil, errSyntax
			}
			body := s[i+1 : end-1]
			toks, err := tokenize(body)
			if err != nil || len(toks) == 0 {
				return nil, errSyntax
			}
			e, err := parseWhole(toks)
			if err != nil {
				return nil, err
			}
			flush()
			parts = append(parts, strPart{e: e})
			i = end
		case '}':
			if i+1 < len(s) && s[i+1] == '}' {
				lit.WriteByte('}')
				i += 2
				continue
			}
			return nil, errSyntax
		default:
			lit.WriteByte(c)
			i++
		}
	}
	flush()
	return &strLit{parts: parts}, nil
}
