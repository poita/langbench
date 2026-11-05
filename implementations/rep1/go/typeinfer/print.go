package typeinfer

// Printing contexts decide where parentheses are needed.
type ctx uint8

const (
	ctxTop   ctx = iota // top level or right of an arrow
	ctxLeft             // left of an arrow
	ctxTuple            // tuple component
	ctxList             // list element
)

// render prints t, naming type variables 'a, 'b, ... in order of first
// appearance.
func (c *Checker) render(t int32) string {
	c.stamp++
	c.nvars = 0
	c.out = c.out[:0]
	c.print(t, ctxTop)
	return string(c.out)
}

func (c *Checker) print(t int32, cx ctx) {
	t = c.find(t)
	n := &c.nodes[t]
	switch n.kind {
	case kVar:
		var idx int32
		if n.stamp == c.stamp {
			idx = n.memo
		} else {
			idx = c.nvars
			c.nvars++
			n.stamp, n.memo = c.stamp, idx
		}
		c.out = append(c.out, '\'', byte('a'+idx%26))
		if q := idx / 26; q > 0 {
			c.out = appendInt(c.out, int(q))
		}
	case kInt:
		c.out = append(c.out, "int"...)
	case kBool:
		c.out = append(c.out, "bool"...)
	case kUnit:
		c.out = append(c.out, "unit"...)
	case kArrow:
		a, b := n.a, n.b
		paren := cx != ctxTop
		if paren {
			c.out = append(c.out, '(')
		}
		c.print(a, ctxLeft)
		c.out = append(c.out, " -> "...)
		c.print(b, ctxTop)
		if paren {
			c.out = append(c.out, ')')
		}
	case kList:
		a := n.a
		c.print(a, ctxList)
		c.out = append(c.out, " list"...)
	case kTuple:
		start, cnt := n.a, n.b
		paren := cx == ctxTuple || cx == ctxList
		if paren {
			c.out = append(c.out, '(')
		}
		for i := int32(0); i < cnt; i++ {
			if i > 0 {
				c.out = append(c.out, " * "...)
			}
			c.print(c.pool[start+i], ctxTuple)
		}
		if paren {
			c.out = append(c.out, ')')
		}
	}
}

func appendInt(b []byte, n int) []byte {
	var tmp [20]byte
	i := len(tmp)
	for n > 0 {
		i--
		tmp[i] = byte('0' + n%10)
		n /= 10
	}
	return append(b, tmp[i:]...)
}
