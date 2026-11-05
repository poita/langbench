package formula

import (
	"fmt"
	"strconv"

	"example.com/spreadsheet/cellref"
)

// SyntaxError describes a malformed formula.
type SyntaxError struct {
	Pos int    // byte offset into the formula text (after the leading '=')
	Msg string // description
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("formula syntax error at offset %d: %s", e.Pos, e.Msg)
}

func joinKey(col, row int) int { return cellref.Key(col, row) }

func splitKey(key int32) (col, row int) { return cellref.Split(int(key)) }

type parser struct {
	src     string
	pos     int
	nodes   []Node
	invalid bool
}

// Parse parses src, the text of a formula without its leading '='.
func Parse(src string) (e *Expr, err error) {
	p := &parser{src: src, nodes: make([]Node, 0, 8)}
	defer func() {
		if r := recover(); r != nil {
			se, ok := r.(*SyntaxError)
			if !ok {
				panic(r)
			}
			e, err = nil, se
		}
	}()
	root := p.expr()
	p.skip()
	if p.pos != len(p.src) {
		p.fail("unexpected trailing input")
	}
	return &Expr{Nodes: p.nodes, Root: root, Invalid: p.invalid}, nil
}

func (p *parser) fail(msg string) { panic(&SyntaxError{Pos: p.pos, Msg: msg}) }

func (p *parser) add(n Node) int32 {
	p.nodes = append(p.nodes, n)
	return int32(len(p.nodes) - 1)
}

func (p *parser) skip() {
	for p.pos < len(p.src) && p.src[p.pos] == ' ' {
		p.pos++
	}
}

func (p *parser) peek() byte {
	p.skip()
	if p.pos < len(p.src) {
		return p.src[p.pos]
	}
	return 0
}

func (p *parser) expect(c byte) {
	if p.peek() != c {
		p.fail("expected '" + string(c) + "'")
	}
	p.pos++
}

func (p *parser) expr() int32 { return p.cmp() }

func (p *parser) cmp() int32 {
	left := p.cat()
	for {
		op, ok := p.cmpOp()
		if !ok {
			return left
		}
		right := p.cat()
		left = p.add(Node{Kind: KindBin, Op: uint8(op), A: left, B: right})
	}
}

func (p *parser) cmpOp() (BinOp, bool) {
	c := p.peek()
	next := byte(0)
	if p.pos+1 < len(p.src) {
		next = p.src[p.pos+1]
	}
	switch c {
	case '=':
		p.pos++
		return OpEq, true
	case '<':
		switch next {
		case '>':
			p.pos += 2
			return OpNe, true
		case '=':
			p.pos += 2
			return OpLe, true
		}
		p.pos++
		return OpLt, true
	case '>':
		if next == '=' {
			p.pos += 2
			return OpGe, true
		}
		p.pos++
		return OpGt, true
	}
	return 0, false
}

func (p *parser) cat() int32 {
	left := p.additive()
	for p.peek() == '&' {
		p.pos++
		right := p.additive()
		left = p.add(Node{Kind: KindBin, Op: uint8(OpCat), A: left, B: right})
	}
	return left
}

func (p *parser) additive() int32 {
	left := p.mul()
	for {
		var op BinOp
		switch p.peek() {
		case '+':
			op = OpAdd
		case '-':
			op = OpSub
		default:
			return left
		}
		p.pos++
		right := p.mul()
		left = p.add(Node{Kind: KindBin, Op: uint8(op), A: left, B: right})
	}
}

func (p *parser) mul() int32 {
	left := p.unary()
	for {
		var op BinOp
		switch p.peek() {
		case '*':
			op = OpMul
		case '/':
			op = OpDiv
		default:
			return left
		}
		p.pos++
		right := p.unary()
		left = p.add(Node{Kind: KindBin, Op: uint8(op), A: left, B: right})
	}
}

func (p *parser) unary() int32 {
	if p.peek() == '-' {
		p.pos++
		x := p.unary()
		return p.add(Node{Kind: KindNeg, A: x})
	}
	return p.primary()
}

func isUpper(c byte) bool { return c >= 'A' && c <= 'Z' }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func (p *parser) primary() int32 {
	c := p.peek()
	switch {
	case isDigit(c):
		start := p.pos
		for p.pos < len(p.src) && isDigit(p.src[p.pos]) {
			p.pos++
		}
		if p.pos+1 < len(p.src) && p.src[p.pos] == '.' && isDigit(p.src[p.pos+1]) {
			p.pos++
			for p.pos < len(p.src) && isDigit(p.src[p.pos]) {
				p.pos++
			}
		}
		f, err := strconv.ParseFloat(p.src[start:p.pos], 64)
		if err != nil {
			p.pos = start
			p.fail("bad number")
		}
		return p.add(Node{Kind: KindNum, Num: f})
	case c == '"':
		p.pos++
		start := p.pos
		for p.pos < len(p.src) && p.src[p.pos] != '"' {
			p.pos++
		}
		if p.pos >= len(p.src) {
			p.fail("unterminated string")
		}
		s := p.src[start:p.pos]
		p.pos++
		return p.add(Node{Kind: KindStr, Str: s})
	case c == '(':
		p.pos++
		x := p.expr()
		p.expect(')')
		return x
	case isUpper(c):
		start := p.pos
		if tok, ok := p.refToken(); ok {
			return p.add(p.refNode(tok))
		}
		p.pos = start
		return p.call()
	}
	p.fail("unexpected input")
	return 0
}

// refToken scans [A-Z]+[0-9]+ at the current position.
func (p *parser) refToken() (string, bool) {
	start := p.pos
	i := start
	for i < len(p.src) && isUpper(p.src[i]) {
		i++
	}
	j := i
	for j < len(p.src) && isDigit(p.src[j]) {
		j++
	}
	if i == start || j == i {
		return "", false
	}
	p.pos = j
	return p.src[start:j], true
}

// refNode builds a KindRef node, flagging the formula as invalid if tok is
// not a valid cell name.
func (p *parser) refNode(tok string) Node {
	key, ok := cellref.ParseKey(tok)
	if !ok {
		p.invalid = true
	}
	return Node{Kind: KindRef, Key: int32(key)}
}

func (p *parser) call() int32 {
	start := p.pos
	for p.pos < len(p.src) && isUpper(p.src[p.pos]) {
		p.pos++
	}
	name := p.src[start:p.pos]
	if name == "IF" {
		p.expect('(')
		c := p.expr()
		p.expect(',')
		a := p.expr()
		p.expect(',')
		b := p.expr()
		p.expect(')')
		return p.add(Node{Kind: KindIf, A: c, B: a, C: b})
	}
	var fn AggFn
	switch name {
	case "SUM":
		fn = FnSum
	case "MIN":
		fn = FnMin
	case "MAX":
		fn = FnMax
	case "AVG":
		fn = FnAvg
	case "COUNT":
		fn = FnCount
	default:
		p.pos = start
		p.fail("unknown function " + strconv.Quote(name))
	}
	p.expect('(')
	var args []int32
	for {
		args = append(args, p.arg())
		if p.peek() == ',' {
			p.pos++
			continue
		}
		break
	}
	p.expect(')')
	return p.add(Node{Kind: KindAgg, Op: uint8(fn), Args: args})
}

// arg parses an aggregate argument: a range REF:REF or an expression.
func (p *parser) arg() int32 {
	if isUpper(p.peek()) {
		start := p.pos
		if first, ok := p.refToken(); ok && p.pos < len(p.src) && p.src[p.pos] == ':' {
			p.pos++
			second, ok := p.refToken()
			if !ok {
				p.fail("expected cell reference after ':'")
			}
			n1, n2 := p.refNode(first), p.refNode(second)
			return p.add(Node{Kind: KindRange, Key: n1.Key, Key2: n2.Key})
		}
		p.pos = start
	}
	return p.expr()
}
