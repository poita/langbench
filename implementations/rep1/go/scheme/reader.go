package scheme

import (
	"io"
	"strconv"
	"strings"

	"example.com/scheme/bigint"
)

// Reader is a recursive-descent reader that turns source text into datums.
type Reader struct {
	src string
	pos int
}

// NewReader returns a Reader over src.
func NewReader(src string) *Reader { return &Reader{src: src} }

// ReadAll parses every datum in src.
func ReadAll(src string) ([]Value, error) {
	r := NewReader(src)
	var out []Value
	for {
		v, err := r.Next()
		if err == io.EOF {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
}

// Next returns the next datum, or io.EOF when the input is exhausted.
func (r *Reader) Next() (v Value, err error) {
	r.skip()
	if r.pos >= len(r.src) {
		return nil, io.EOF
	}
	defer func() {
		if p := recover(); p != nil {
			if se, ok := p.(*SyntaxError); ok {
				v, err = nil, se
				return
			}
			panic(p)
		}
	}()
	return r.datum(), nil
}

func (r *Reader) fail(msg string) {
	panic(&SyntaxError{Msg: msg, Pos: r.pos})
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' }

func isDelim(c byte) bool {
	return isSpace(c) || c == '(' || c == ')' || c == '\'' || c == '"' || c == ';'
}

// skip consumes whitespace and comments.
func (r *Reader) skip() {
	for r.pos < len(r.src) {
		c := r.src[r.pos]
		switch {
		case isSpace(c):
			r.pos++
		case c == ';':
			for r.pos < len(r.src) && r.src[r.pos] != '\n' {
				r.pos++
			}
		default:
			return
		}
	}
}

func (r *Reader) datum() Value {
	r.skip()
	if r.pos >= len(r.src) {
		r.fail("unexpected end of input")
	}
	switch c := r.src[r.pos]; c {
	case '(':
		r.pos++
		return r.list()
	case ')':
		r.fail("unexpected ')'")
	case '\'':
		r.pos++
		return List(Intern("quote"), r.datum())
	case '"':
		r.pos++
		return r.str()
	}
	return r.atom()
}

// list reads the rest of a list after its opening parenthesis.
func (r *Reader) list() Value {
	var head Value = Nil
	var tail *Pair
	appendItem := func(v Value) {
		p := &Pair{v, Nil}
		if tail == nil {
			head = p
		} else {
			tail.Cdr = p
		}
		tail = p
	}
	for {
		r.skip()
		if r.pos >= len(r.src) {
			r.fail("unterminated list")
		}
		c := r.src[r.pos]
		if c == ')' {
			r.pos++
			return head
		}
		if c == '.' && (r.pos+1 >= len(r.src) || isDelim(r.src[r.pos+1])) && tail != nil {
			r.pos++
			tail.Cdr = r.datum()
			r.skip()
			if r.pos >= len(r.src) || r.src[r.pos] != ')' {
				r.fail("expected ')' after dotted tail")
			}
			r.pos++
			return head
		}
		appendItem(r.datum())
	}
}

func (r *Reader) str() Value {
	var sb strings.Builder
	for r.pos < len(r.src) {
		c := r.src[r.pos]
		r.pos++
		switch c {
		case '"':
			return NewString(sb.String())
		case '\\':
			if r.pos >= len(r.src) {
				r.fail("unterminated string")
			}
			e := r.src[r.pos]
			r.pos++
			switch e {
			case 'n':
				sb.WriteByte('\n')
			case 't':
				sb.WriteByte('\t')
			default: // \" and \\ (and, leniently, anything else)
				sb.WriteByte(e)
			}
		default:
			sb.WriteByte(c)
		}
	}
	r.fail("unterminated string")
	return nil
}

func (r *Reader) atom() Value {
	start := r.pos
	for r.pos < len(r.src) && !isDelim(r.src[r.pos]) {
		r.pos++
	}
	tok := r.src[start:r.pos]
	switch tok {
	case "#t":
		return True
	case "#f":
		return False
	}
	if v, ok := parseInteger(tok); ok {
		return v
	}
	return Intern(tok)
}

// parseInteger recognises an optional sign followed by one or more ASCII
// digits.
func parseInteger(tok string) (Value, bool) {
	digits := tok
	if len(digits) > 0 && (digits[0] == '+' || digits[0] == '-') {
		digits = digits[1:]
	}
	if len(digits) == 0 {
		return nil, false
	}
	for i := 0; i < len(digits); i++ {
		if digits[i] < '0' || digits[i] > '9' {
			return nil, false
		}
	}
	if len(digits) <= 18 {
		n, err := strconv.ParseInt(tok, 10, 64)
		if err == nil {
			return Int(n), true
		}
	}
	b, ok := bigint.Parse(tok)
	if !ok {
		return nil, false
	}
	return NewBig(b), true
}
