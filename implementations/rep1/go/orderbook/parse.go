package orderbook

import (
	"fmt"
	"slices"
)

// Script is a parsed command stream together with the sorted, de-duplicated
// table of every price that appears in a LIMIT or REPLACE command.
type Script struct {
	Commands []Command
	Prices   []int64
}

// ParseError describes malformed input.
type ParseError struct {
	Line int // 1-based line number
	Msg  string
}

func (e *ParseError) Error() string {
	return fmt.Sprintf("orderbook: line %d: %s", e.Line, e.Msg)
}

// parser is a hand-written cursor over the input buffer.
type parser struct {
	buf  []byte
	pos  int
	line int
}

// token returns the bytes up to the next space or newline (or end of input),
// consumes that one terminator and reports it (0 at end of input).
func (p *parser) token() (tok []byte, term byte) {
	start := p.pos
	for p.pos < len(p.buf) {
		c := p.buf[p.pos]
		if c == ' ' || c == '\n' {
			p.pos++
			return p.buf[start : p.pos-1], c
		}
		p.pos++
	}
	return p.buf[start:], 0
}

func (p *parser) fail(msg string) error { return &ParseError{Line: p.line, Msg: msg} }

func (p *parser) number(tok []byte) (int64, error) {
	if len(tok) == 0 || len(tok) > 18 {
		return 0, p.fail("bad number")
	}
	var v int64
	for _, c := range tok {
		if c < '0' || c > '9' {
			return 0, p.fail("bad number")
		}
		v = v*10 + int64(c-'0')
	}
	return v, nil
}

func (p *parser) side(tok []byte) (Side, error) {
	switch string(tok) {
	case "BUY":
		return Buy, nil
	case "SELL":
		return Sell, nil
	}
	return 0, p.fail("bad side")
}

// Parse parses a whole input: a line with the command count N followed by N
// command lines (see the package documentation of the CLI for the grammar).
// The final newline is optional. The returned commands' IDs alias input.
func Parse(input []byte) (*Script, error) {
	p := &parser{buf: input, line: 1}
	tok, _ := p.token()
	n, err := p.number(tok)
	if err != nil {
		return nil, err
	}
	s := &Script{Commands: make([]Command, 0, min(n, 1<<22))}
	var prices []int64
	for i := int64(0); i < n; i++ {
		p.line = int(i) + 2
		if p.pos >= len(p.buf) {
			return nil, p.fail("unexpected end of input")
		}
		c, err := p.command()
		if err != nil {
			return nil, err
		}
		if c.Kind == KindLimit || c.Kind == KindReplace {
			prices = append(prices, c.Price)
		}
		s.Commands = append(s.Commands, c)
	}
	slices.Sort(prices)
	s.Prices = slices.Compact(prices)
	for i := range s.Commands {
		c := &s.Commands[i]
		if c.Kind == KindLimit || c.Kind == KindReplace {
			r, _ := slices.BinarySearch(s.Prices, c.Price)
			c.rank = int32(r)
		}
	}
	return s, nil
}

// command parses one command line. Commands are recognised by their first
// byte; all other tokens are identified by position, so ids may equal
// keywords.
func (p *parser) command() (Command, error) {
	var c Command
	kw, term := p.token()
	if len(kw) == 0 {
		return c, p.fail("empty command")
	}
	var err error
	// need reads the next token, which must exist (the previous terminator
	// was a space).
	need := func(prev byte) ([]byte, byte, error) {
		if prev != ' ' {
			return nil, 0, p.fail("missing field")
		}
		t, tm := p.token()
		return t, tm, nil
	}
	var tok []byte
	switch kw[0] {
	case 'L':
		c.Kind = KindLimit
		if c.ID, term, err = need(term); err != nil {
			return c, err
		}
		if tok, term, err = need(term); err != nil {
			return c, err
		}
		if c.Side, err = p.side(tok); err != nil {
			return c, err
		}
		if tok, term, err = need(term); err != nil {
			return c, err
		}
		if c.Price, err = p.number(tok); err != nil {
			return c, err
		}
		if tok, term, err = need(term); err != nil {
			return c, err
		}
		if c.Qty, err = p.number(tok); err != nil {
			return c, err
		}
		if term == ' ' {
			tok, _ = p.token()
			switch string(tok) {
			case "IOC":
				c.TIF = IOC
			case "FOK":
				c.TIF = FOK
			default:
				return c, p.fail("bad time-in-force flag")
			}
		}
	case 'M':
		c.Kind = KindMarket
		if c.ID, term, err = need(term); err != nil {
			return c, err
		}
		if tok, term, err = need(term); err != nil {
			return c, err
		}
		if c.Side, err = p.side(tok); err != nil {
			return c, err
		}
		if tok, _, err = need(term); err != nil {
			return c, err
		}
		if c.Qty, err = p.number(tok); err != nil {
			return c, err
		}
	case 'C':
		c.Kind = KindCancel
		if c.ID, _, err = need(term); err != nil {
			return c, err
		}
	case 'R':
		c.Kind = KindReplace
		if c.ID, term, err = need(term); err != nil {
			return c, err
		}
		if tok, term, err = need(term); err != nil {
			return c, err
		}
		if c.Price, err = p.number(tok); err != nil {
			return c, err
		}
		if tok, _, err = need(term); err != nil {
			return c, err
		}
		if c.Qty, err = p.number(tok); err != nil {
			return c, err
		}
	case 'B':
		c.Kind = KindBook
	default:
		return c, p.fail("unknown command")
	}
	return c, nil
}
