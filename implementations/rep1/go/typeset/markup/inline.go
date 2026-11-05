package markup

import "typeset/diag"

// srcText is a run of source characters, each with its source position, so
// that errors found while scanning can be located exactly.
type srcText struct {
	R         []rune
	Line, Col []int32 // Col is 1-based
}

func (s *srcText) add(r rune, line, col int) {
	s.R = append(s.R, r)
	s.Line = append(s.Line, int32(line))
	s.Col = append(s.Col, int32(col))
}

// textLine is one source line of a block's text with its leading spaces
// already dropped; col0 is the 0-based source column of r[0].
type textLine struct {
	r    []rune
	line int
	col0 int
}

func newTextLine(line []rune, lineNo, from int) textLine {
	for from < len(line) && line[from] == ' ' {
		from++
	}
	return textLine{r: line[from:], line: lineNo, col0: from}
}

// join concatenates the lines with a single joining space.
func join(ls []textLine) srcText {
	var s srcText
	for i, l := range ls {
		if i > 0 {
			p := ls[i-1]
			s.add(' ', p.line, p.col0+len(p.r)+1)
		}
		for k, r := range l.r {
			s.add(r, l.line, l.col0+k+1)
		}
	}
	return s
}

type fnFrame struct {
	outer      []Unit
	outerStyle Style
	num        int
}

type openTag struct {
	pos   int
	style Style // style to restore when the tag closes
	fn    *fnFrame
}

// scan resolves the inline constructs of text into units. allowFn says
// whether {n|...} is permitted. Errors panic with *diag.Error.
func (p *parser) scan(text srcText, allowFn bool) []Unit {
	var out []Unit
	cur := Style{}
	var stack []openTag
	fail := func(i int, code string) {
		panic(diag.New("document.cdx", int(text.Line[i]), int(text.Col[i]), code))
	}
	var fn *fnFrame // innermost open footnote (there is at most one)
	push := func(u Unit) { out = append(out, u) }
	R := text.R
	for i := 0; i < len(R); i++ {
		c := R[i]
		switch c {
		case ' ':
			if len(out) > 0 && out[len(out)-1].Kind != UGlue {
				push(Unit{Kind: UGlue, Style: p.styleID(cur)})
			}
		case '~':
			push(Unit{Kind: URigid, Style: p.styleID(cur)})
		case '\\':
			if i+1 >= len(R) {
				fail(i, "bad-escape")
			}
			i++
			switch R[i] {
			case '{', '}', '|', '\\', '@', '~':
				push(Unit{Kind: UChar, Style: p.styleID(cur), R: R[i]})
			case ' ':
				push(Unit{Kind: URigid, Style: p.styleID(cur)})
			case '-':
				push(Unit{Kind: UDisc, Style: p.styleID(cur)})
			default:
				fail(i-1, "bad-escape")
			}
		case '{':
			if i+2 >= len(R) || R[i+2] != '|' {
				fail(i, "unknown-inline")
			}
			tag := R[i+1]
			switch tag {
			case 'b', 'i', 'm', '+', '-', 'n':
			default:
				fail(i, "unknown-inline")
			}
			t := openTag{pos: i, style: cur}
			if tag == 'n' {
				if fn != nil {
					fail(i, "nested-footnote")
				}
				if !allowFn {
					fail(i, "footnote-not-allowed")
				}
				p.doc.Footnotes = append(p.doc.Footnotes, nil)
				fn = &fnFrame{outer: out, outerStyle: cur, num: len(p.doc.Footnotes)}
				t.fn = fn
				out = nil
				cur = Style{}
			} else {
				switch tag {
				case 'b':
					cur.Bold = true
				case 'i':
					cur.Italic = true
				case 'm':
					cur.Mono = true
				case '+', '-':
					cur.Steps += string(tag)
				}
			}
			stack = append(stack, t)
			i += 2
		case '}':
			if len(stack) == 0 {
				fail(i, "stray-brace")
			}
			t := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			cur = t.style
			if t.fn != nil {
				if n := len(out); n > 0 && out[n-1].Kind == UGlue {
					out = out[:n-1]
				}
				p.doc.Footnotes[t.fn.num-1] = out
				out = append(t.fn.outer, Unit{Kind: UMark, Style: p.styleID(t.fn.outerStyle), Aux: int64(t.fn.num)})
				fn = nil
			}
		default:
			push(Unit{Kind: UChar, Style: p.styleID(cur), R: c})
		}
	}
	if len(stack) > 0 {
		fail(stack[len(stack)-1].pos, "unclosed-inline")
	}
	if n := len(out); n > 0 && out[n-1].Kind == UGlue {
		out = out[:n-1]
	}
	return out
}

func (p *parser) styleID(s Style) int32 {
	if id, ok := p.styleIdx[s]; ok {
		return id
	}
	id := int32(len(p.doc.Styles))
	p.doc.Styles = append(p.doc.Styles, s)
	p.styleIdx[s] = id
	return id
}
