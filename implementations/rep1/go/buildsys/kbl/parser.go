package kbl

import (
	"strings"

	"buildsys/kilnerr"
)

// syntaxError is the panic value used inside the parser; it is converted to
// an E_PARSE at the enclosing logical line.
type syntaxError struct{}

func fail() { panic(syntaxError{}) }

// exprParser parses an expression from a token slice.
type exprParser struct {
	toks []token
	pos  int
}

func (p *exprParser) done() bool { return p.pos >= len(p.toks) }

func (p *exprParser) peek() (token, bool) {
	if p.pos < len(p.toks) {
		return p.toks[p.pos], true
	}
	return token{}, false
}

func (p *exprParser) isPunct(s string) bool {
	t, ok := p.peek()
	return ok && t.kind == tPunct && t.text == s
}

func (p *exprParser) isOp(s string) bool {
	t, ok := p.peek()
	return ok && t.kind == tOp && t.text == s
}

func (p *exprParser) expectPunct(s string) {
	if !p.isPunct(s) {
		fail()
	}
	p.pos++
}

func (p *exprParser) expectEnd() {
	if !p.done() {
		fail()
	}
}

// ident consumes an identifier that is not a reserved word.
func (p *exprParser) ident() string {
	t, ok := p.peek()
	if !ok || t.kind != tIdent || reserved[t.text] {
		fail()
	}
	p.pos++
	return t.text
}

// anyIdent consumes an identifier, reserved or not (call-name positions).
func (p *exprParser) anyIdent() string {
	t, ok := p.peek()
	if !ok || t.kind != tIdent {
		fail()
	}
	p.pos++
	return t.text
}

func (p *exprParser) expr() expr {
	e := p.or()
	for p.isOp("|>") {
		p.pos++
		name := p.anyIdent()
		args := []expr{e}
		if p.isPunct("(") {
			args = append(args, p.callArgs()...)
		}
		e = &call{name: name, args: args}
	}
	return e
}

// callArgs parses "(" [expr {"," expr} [","]] ")".
func (p *exprParser) callArgs() []expr {
	p.expectPunct("(")
	var args []expr
	for !p.isPunct(")") {
		args = append(args, p.expr())
		if p.isPunct(",") {
			p.pos++
			continue
		}
		break
	}
	p.expectPunct(")")
	return args
}

func (p *exprParser) or() expr {
	e := p.and()
	for p.isOp("||") {
		p.pos++
		e = &binary{op: "||", l: e, r: p.and()}
	}
	return e
}

func (p *exprParser) and() expr {
	e := p.cmp()
	for p.isOp("&&") {
		p.pos++
		e = &binary{op: "&&", l: e, r: p.cmp()}
	}
	return e
}

func (p *exprParser) cmp() expr {
	e := p.cat()
	for {
		t, ok := p.peek()
		if !ok || t.kind != tOp {
			return e
		}
		switch t.text {
		case "==", "!=", "<", "<=", ">", ">=":
			p.pos++
			e = &binary{op: t.text, l: e, r: p.cat()}
		default:
			return e
		}
	}
}

func (p *exprParser) cat() expr {
	e := p.str()
	for p.isOp("++") {
		p.pos++
		e = &binary{op: "++", l: e, r: p.str()}
	}
	return e
}

func (p *exprParser) str() expr {
	e := p.add()
	for p.isOp("~") {
		p.pos++
		e = &binary{op: "~", l: e, r: p.add()}
	}
	return e
}

func (p *exprParser) add() expr {
	e := p.mul()
	for p.isOp("+") || p.isOp("-") {
		op := p.toks[p.pos].text
		p.pos++
		e = &binary{op: op, l: e, r: p.mul()}
	}
	return e
}

func (p *exprParser) mul() expr {
	e := p.unary()
	for p.isOp("*") || p.isOp("/") || p.isOp("%") {
		op := p.toks[p.pos].text
		p.pos++
		e = &binary{op: op, l: e, r: p.unary()}
	}
	return e
}

func (p *exprParser) unary() expr {
	if p.isOp("!") || p.isOp("-") {
		op := p.toks[p.pos].text
		p.pos++
		return &unary{op: op, x: p.unary()}
	}
	return p.postfix()
}

func (p *exprParser) postfix() expr {
	e := p.primary()
	for p.isPunct("[") {
		p.pos++
		i := p.expr()
		p.expectPunct("]")
		e = &indexExpr{x: e, i: i}
	}
	return e
}

func (p *exprParser) primary() expr {
	t, ok := p.peek()
	if !ok {
		fail()
	}
	switch t.kind {
	case tInt:
		p.pos++
		return &intLit{t.ival}
	case tStr:
		p.pos++
		return parseStringLiteral(t.text)
	case tIdent:
		p.pos++
		if p.isPunct("(") {
			return &call{name: t.text, args: p.callArgs()}
		}
		switch t.text {
		case "true":
			return &boolLit{true}
		case "false":
			return &boolLit{false}
		}
		if reserved[t.text] {
			fail()
		}
		return &varRef{t.text}
	case tPunct:
		switch t.text {
		case "(":
			p.pos++
			e := p.expr()
			p.expectPunct(")")
			return e
		case "[":
			p.pos++
			var elems []expr
			for !p.isPunct("]") {
				elems = append(elems, p.expr())
				if p.isPunct(",") {
					p.pos++
					continue
				}
				break
			}
			p.expectPunct("]")
			return &listLit{elems}
		}
	}
	fail()
	return nil
}

// parseStringLiteral parses a quoted literal token (including its quotes).
func parseStringLiteral(raw string) expr {
	if raw[0] == '\'' {
		return &strLit{parts: []strPart{{lit: strings.ReplaceAll(raw[1:len(raw)-1], "''", "'")}}}
	}
	body := raw[1 : len(raw)-1]
	var parts []strPart
	var lit strings.Builder
	flush := func() {
		if lit.Len() > 0 {
			parts = append(parts, strPart{lit: lit.String()})
			lit.Reset()
		}
	}
	for i := 0; i < len(body); {
		c := body[i]
		switch c {
		case '\\':
			if i+1 >= len(body) {
				fail()
			}
			switch body[i+1] {
			case '\\', '"':
				lit.WriteByte(body[i+1])
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
			if i+1 < len(body) && body[i+1] == '{' {
				lit.WriteByte('{')
				i += 2
				continue
			}
			end, ok := skipRegion(body, i+1)
			if !ok {
				fail()
			}
			toks, ok := tokenize(body[i+1 : end-1])
			if !ok || len(toks) == 0 {
				fail()
			}
			ep := &exprParser{toks: toks}
			e := ep.expr()
			ep.expectEnd()
			flush()
			parts = append(parts, strPart{e: e, isEx: true})
			i = end
		case '}':
			if i+1 < len(body) && body[i+1] == '}' {
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

// ---- statements and blocks ----

type frameKind uint8

const (
	fWhen frameKind = iota
	fEach
	fRule
	fStep
)

type frame struct {
	kind  frameKind
	line  int
	stmts []stmt // body being accumulated
	// when
	when      *whenStmt
	inOther   bool
	each      *eachStmt
	rule      *ruleStmt
	stepField []stepField
}

// parseFile parses the logical lines of one build file. On a grammar error it
// returns the line number (> 0) of the offending logical line.
func parseFile(lines []logicalLine) ([]stmt, int) {
	var top []stmt
	var stack []*frame
	emit := func(s stmt) {
		if len(stack) == 0 {
			top = append(top, s)
		} else {
			f := stack[len(stack)-1]
			f.stmts = append(f.stmts, s)
		}
	}
	for _, ll := range lines {
		if !parseLine(ll, &stack, emit) {
			return nil, ll.line
		}
	}
	if len(stack) > 0 {
		return nil, stack[len(stack)-1].line
	}
	return top, 0
}

func parseLine(ll logicalLine, stack *[]*frame, emit func(stmt)) (ok bool) {
	defer func() {
		if r := recover(); r != nil {
			if _, is := r.(syntaxError); !is {
				panic(r)
			}
			ok = false
		}
	}()
	toks := ll.toks
	var cur *frame
	if len(*stack) > 0 {
		cur = (*stack)[len(*stack)-1]
	}
	first := toks[0]
	last := toks[len(toks)-1]

	// Block terminators.
	if first.is(tPunct, "}") {
		if cur == nil {
			fail()
		}
		if len(toks) == 1 {
			*stack = (*stack)[:len(*stack)-1]
			emit(closeFrame(cur))
			return true
		}
		if cur.kind != fWhen || cur.inOther {
			fail()
		}
		switch {
		case toks[1].is(tIdent, "elsewhen") && last.is(tPunct, "{"):
			ep := &exprParser{toks: toks[2 : len(toks)-1]}
			cond := ep.expr()
			ep.expectEnd()
			cur.when.bodies = append(cur.when.bodies, cur.stmts)
			cur.when.conds = append(cur.when.conds, cond)
			cur.stmts = nil
			cur.line = ll.line
		case len(toks) == 3 && toks[1].is(tIdent, "otherwise") && last.is(tPunct, "{"):
			cur.when.bodies = append(cur.when.bodies, cur.stmts)
			cur.stmts = nil
			cur.inOther = true
			cur.when.hasOther = true
			cur.line = ll.line
		default:
			fail()
		}
		return true
	}

	// Block headers.
	if last.is(tPunct, "{") {
		if cur != nil && cur.kind == fStep {
			fail()
		}
		hdr := toks[:len(toks)-1]
		if len(hdr) == 0 {
			fail()
		}
		f := &frame{line: ll.line}
		ep := &exprParser{toks: hdr[1:]}
		switch {
		case hdr[0].is(tIdent, "step"):
			if len(hdr) != 1 {
				fail()
			}
			f.kind = fStep
		case hdr[0].is(tIdent, "when"):
			f.kind = fWhen
			cond := ep.expr()
			ep.expectEnd()
			f.when = &whenStmt{conds: []expr{cond}}
		case hdr[0].is(tIdent, "each"):
			f.kind = fEach
			e := &eachStmt{}
			e.name = ep.ident()
			if ep.isPunct(",") {
				ep.pos++
				e.index = e.name
				e.name = ep.ident()
				if e.index == e.name {
					fail()
				}
			}
			if t, ok := ep.peek(); !ok || !t.is(tIdent, "in") {
				fail()
			}
			ep.pos++
			e.subject = ep.expr()
			ep.expectEnd()
			f.each = e
		case hdr[0].is(tIdent, "rule"):
			f.kind = fRule
			r := &ruleStmt{name: ep.ident()}
			ep.expectPunct("(")
			seen := map[string]bool{}
			sawDefault := false
			for !ep.isPunct(")") {
				pr := param{name: ep.ident()}
				if seen[pr.name] {
					fail()
				}
				seen[pr.name] = true
				if ep.isPunct("=") {
					ep.pos++
					pr.def = ep.expr()
					sawDefault = true
				} else if sawDefault {
					fail()
				}
				r.params = append(r.params, pr)
				if ep.isPunct(",") {
					ep.pos++
					continue
				}
				break
			}
			ep.expectPunct(")")
			ep.expectEnd()
			f.rule = r
		default:
			fail()
		}
		*stack = append(*stack, f)
		return true
	}

	// Simple statements.
	if cur != nil && cur.kind == fStep {
		cur.stepField = append(cur.stepField, parseStepField(toks))
		return true
	}
	emit(parseSimple(toks))
	return true
}

func closeFrame(f *frame) stmt {
	switch f.kind {
	case fWhen:
		if f.inOther {
			f.when.otherwise = f.stmts
		} else {
			f.when.bodies = append(f.when.bodies, f.stmts)
		}
		return f.when
	case fEach:
		f.each.body = f.stmts
		return f.each
	case fRule:
		f.rule.body = f.stmts
		return f.rule
	default:
		return &stepStmt{fields: f.stepField}
	}
}

func parseStepField(toks []token) stepField {
	ep := &exprParser{toks: toks}
	t := toks[0]
	if t.kind != tIdent {
		fail()
	}
	ep.pos = 1
	switch t.text {
	case "out", "in", "after", "cost", "depfile":
		e := ep.expr()
		ep.expectEnd()
		return stepField{kind: t.text, e: e}
	case "cmd":
		name := ep.anyIdent()
		args := ep.callArgs()
		ep.expectEnd()
		return stepField{kind: "cmd", cmd: name, args: args}
	}
	fail()
	return stepField{}
}

func parseSimple(toks []token) stmt {
	ep := &exprParser{toks: toks, pos: 1}
	t := toks[0]
	if t.kind != tIdent {
		fail()
	}
	switch t.text {
	case "let", "set":
		name := ep.ident()
		ep.expectPunct("=")
		e := ep.expr()
		ep.expectEnd()
		if t.text == "let" {
			return &letStmt{name, e}
		}
		return &setStmt{name, e}
	case "include":
		e := ep.expr()
		ep.expectEnd()
		return &includeStmt{e}
	case "abort":
		e := ep.expr()
		ep.expectEnd()
		return &abortStmt{e}
	case "default":
		e := ep.expr()
		ep.expectEnd()
		return &defaultStmt{e}
	case "phony":
		name := ep.ident()
		ep.expectPunct("=")
		e := ep.expr()
		ep.expectEnd()
		return &phonyStmt{name, e}
	case "use":
		name := ep.anyIdent()
		ep.expectPunct("(")
		var args []useArg
		sawKw := false
		for !ep.isPunct(")") {
			var a useArg
			if t, ok := ep.peek(); ok && t.kind == tIdent && !reserved[t.text] &&
				ep.pos+1 < len(ep.toks) && ep.toks[ep.pos+1].is(tPunct, "=") {
				a.kw = t.text
				ep.pos += 2
				sawKw = true
			} else if sawKw {
				fail()
			}
			a.e = ep.expr()
			args = append(args, a)
			if ep.isPunct(",") {
				ep.pos++
				continue
			}
			break
		}
		ep.expectPunct(")")
		ep.expectEnd()
		return &useStmt{name, args}
	}
	fail()
	return nil
}

// ParseFile lexes and parses a build file. file is only used for the error
// detail. It is exported for tooling and tests.
func ParseFile(file, src string) *kilnerr.Error {
	_, err := parseSource(file, src)
	return err
}

func parseSource(file, src string) ([]stmt, *kilnerr.Error) {
	lines, errLine := lexFile(src)
	if errLine == 0 {
		var stmts []stmt
		stmts, errLine = parseFile(lines)
		if errLine == 0 {
			return stmts, nil
		}
	}
	return nil, kilnerr.New(kilnerr.Parse, file+":"+itoa(errLine))
}
