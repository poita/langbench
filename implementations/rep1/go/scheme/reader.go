package scheme

import "example.com/scheme/bigint"

// reader scans an in-memory source buffer by index and builds datums.
type reader struct {
	in  *Interp
	src []byte
	pos int
}

func isDelim(c byte) bool {
	switch c {
	case ' ', '\t', '\r', '\n', '(', ')', '\'', '"', ';':
		return true
	}
	return false
}

func (r *reader) skipSpace() {
	for r.pos < len(r.src) {
		switch r.src[r.pos] {
		case ' ', '\t', '\r', '\n':
			r.pos++
		case ';':
			for r.pos < len(r.src) && r.src[r.pos] != '\n' {
				r.pos++
			}
		default:
			return
		}
	}
}

// next reads the next datum. It returns ok == false at end of input.
func (r *reader) next() (v Value, ok bool) {
	r.skipSpace()
	if r.pos >= len(r.src) {
		return Value{}, false
	}
	return r.datum(), true
}

func (r *reader) datum() Value {
	r.skipSpace()
	if r.pos >= len(r.src) {
		throw(ErrSyntax)
	}
	switch c := r.src[r.pos]; c {
	case '(':
		r.pos++
		return r.list()
	case ')':
		throw(ErrSyntax)
	case '\'':
		r.pos++
		d := r.datum()
		return cons(r.in.symVals[symQuote], cons(d, nilV))
	case '"':
		r.pos++
		return r.str()
	}
	return r.atom()
}

// list reads the elements after '(' up to and including ')'. Elements are
// collected with a tail pointer, so the cost is linear in the list length.
func (r *reader) list() Value {
	head := nilV
	var tail *Pair
	for {
		r.skipSpace()
		if r.pos >= len(r.src) {
			throw(ErrSyntax)
		}
		c := r.src[r.pos]
		if c == ')' {
			r.pos++
			return head
		}
		if c == '.' && (r.pos+1 >= len(r.src) || isDelim(r.src[r.pos+1])) && tail != nil {
			r.pos++
			tail.cdr = r.datum()
			r.skipSpace()
			if r.pos >= len(r.src) || r.src[r.pos] != ')' {
				throw(ErrSyntax)
			}
			r.pos++
			return head
		}
		cell := &Pair{car: r.datum(), cdr: nilV}
		if tail == nil {
			head = Value{t: tPair, ref: cell}
		} else {
			tail.cdr = Value{t: tPair, ref: cell}
		}
		tail = cell
	}
}

func (r *reader) str() Value {
	var buf []byte
	for r.pos < len(r.src) {
		c := r.src[r.pos]
		r.pos++
		switch c {
		case '"':
			return Str(string(buf))
		case '\\':
			if r.pos >= len(r.src) {
				throw(ErrSyntax)
			}
			e := r.src[r.pos]
			r.pos++
			switch e {
			case 'n':
				buf = append(buf, '\n')
			case 't':
				buf = append(buf, '\t')
			default: // \" and \\ (no other escapes occur)
				buf = append(buf, e)
			}
		default:
			buf = append(buf, c)
		}
	}
	throw(ErrSyntax)
	return Value{}
}

func (r *reader) atom() Value {
	start := r.pos
	for r.pos < len(r.src) && !isDelim(r.src[r.pos]) {
		r.pos++
	}
	tok := r.src[start:r.pos]
	if len(tok) == 2 && tok[0] == '#' {
		switch tok[1] {
		case 't':
			return trueV
		case 'f':
			return falsV
		}
	}
	if v, ok := parseInteger(tok); ok {
		return v
	}
	return r.in.intern(string(tok))
}

// parseInteger recognises [+-]?[0-9]+ and builds a fixnum or bignum.
func parseInteger(tok []byte) (Value, bool) {
	i := 0
	if len(tok) > 0 && (tok[0] == '+' || tok[0] == '-') {
		i = 1
	}
	if i == len(tok) {
		return Value{}, false
	}
	for j := i; j < len(tok); j++ {
		if tok[j] < '0' || tok[j] > '9' {
			return Value{}, false
		}
	}
	if len(tok)-i <= 18 {
		var n int64
		for j := i; j < len(tok); j++ {
			n = n*10 + int64(tok[j]-'0')
		}
		if tok[0] == '-' {
			n = -n
		}
		return fix(n), true
	}
	b, _ := bigint.Parse(string(tok))
	return fromBig(b), true
}
