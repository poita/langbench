package types

import (
	"strconv"
	"strings"
)

// String renders t in the concrete syntax of the language: type variables are
// named 'a, 'b, ... in order of first appearance, `->` associates to the
// right, and parentheses appear only where needed. Unbound and quantified
// variables are printed alike.
func (t *Type) String() string {
	var p printer
	p.names = make(map[*Type]int)
	p.write(t, ctxTop)
	return p.sb.String()
}

// String renders the body of the scheme; see [Type.String].
func (s *Scheme) String() string { return s.Type.String() }

// VarName returns the name of the i-th type variable (counting from 0): 'a to
// 'z, then 'a1 to 'z1, 'a2, ...
func VarName(i int) string {
	var b [24]byte
	buf := append(b[:0], '\'', byte('a'+i%26))
	if i >= 26 {
		buf = strconv.AppendInt(buf, int64(i/26), 10)
	}
	return string(buf)
}

// Contexts in which a type is printed, in the order of increasing need for
// parentheses.
const (
	ctxTop    = iota // top level or right of an arrow: nothing needs parentheses
	ctxArrowL        // left of an arrow: functions need parentheses
	ctxElem          // tuple component or list element: functions and tuples do
)

type printer struct {
	sb    strings.Builder
	names map[*Type]int
}

func (p *printer) write(t *Type, ctx int) {
	t = find(t)
	switch t.kind {
	case KindVar:
		n, ok := p.names[t]
		if !ok {
			n = len(p.names)
			p.names[t] = n
		}
		p.sb.WriteString(VarName(n))
	case KindInt:
		p.sb.WriteString("int")
	case KindBool:
		p.sb.WriteString("bool")
	case KindUnit:
		p.sb.WriteString("unit")
	case KindArrow:
		paren := ctx >= ctxArrowL
		if paren {
			p.sb.WriteByte('(')
		}
		p.write(t.args[0], ctxArrowL)
		p.sb.WriteString(" -> ")
		p.write(t.args[1], ctxTop)
		if paren {
			p.sb.WriteByte(')')
		}
	case KindTuple:
		paren := ctx >= ctxElem
		if paren {
			p.sb.WriteByte('(')
		}
		for i, a := range t.args {
			if i > 0 {
				p.sb.WriteString(" * ")
			}
			p.write(a, ctxElem)
		}
		if paren {
			p.sb.WriteByte(')')
		}
	case KindList:
		p.write(t.args[0], ctxElem)
		p.sb.WriteString(" list")
	}
}
