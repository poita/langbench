package codexa

import "typeset/diag"

// srcPos is a 1-based source position.
type srcPos struct{ line, col int }

// text is a run of source characters with the source position of each.
type text struct {
	r   []rune
	pos []srcPos
}

func (t *text) add(r rune, p srcPos) {
	t.r = append(t.r, r)
	t.pos = append(t.pos, p)
}

// addLine appends a source line starting at rune index from, dropping nothing
// else. Columns are 1-based.
func (t *text) addLine(line []rune, from, lineNo int) {
	for i := from; i < len(line); i++ {
		t.add(line[i], srcPos{lineNo, i + 1})
	}
}

type frame struct {
	tag    byte
	saved  Style
	open   int
	parent []Unit // the unit list to resume when a footnote closes
	note   *Footnote
	isNote bool
}

// scanner holds the state shared by the inline scans of a document.
type scanner struct {
	doc *Document
}

// scan resolves the inline constructs of t. forbidNotes makes {n|...} an
// error (headings and figure captions).
func (sc *scanner) scan(t *text, forbidNotes bool) (Inline, *diag.Error) {
	var units []Unit
	var style Style
	var stack []frame
	inNote := false
	fail := func(i int, code string) (Inline, *diag.Error) {
		return nil, &diag.Error{File: File, Line: t.pos[i].line, Col: t.pos[i].col, Code: code}
	}
	r := t.r
	for i := 0; i < len(r); i++ {
		c := r[i]
		switch c {
		case ' ':
			units = append(units, Unit{Kind: Space, Style: style})
		case '~':
			units = append(units, Unit{Kind: Rigid, Style: style})
		case '\\':
			if i+1 >= len(r) {
				return fail(i, diag.BadEscape)
			}
			i++
			switch r[i] {
			case '{', '}', '|', '\\', '@', '~':
				units = append(units, Unit{Kind: Char, R: r[i], Style: style})
			case ' ':
				units = append(units, Unit{Kind: Rigid, Style: style})
			case '-':
				units = append(units, Unit{Kind: Disc, Style: style})
			default:
				return fail(i-1, diag.BadEscape)
			}
		case '{':
			if i+2 >= len(r) || r[i+2] != '|' {
				return fail(i, diag.UnknownInline)
			}
			tag := r[i+1]
			switch tag {
			case 'b', 'i', 'm', '+', '-', 'n':
			default:
				return fail(i, diag.UnknownInline)
			}
			f := frame{tag: byte(tag), saved: style, open: i}
			if tag == 'n' {
				if inNote {
					return fail(i, diag.NestedFootnote)
				}
				if forbidNotes {
					return fail(i, diag.FootnoteNotAllowed)
				}
				n := &Footnote{Number: len(sc.doc.Footnotes) + 1}
				sc.doc.Footnotes = append(sc.doc.Footnotes, n)
				f.isNote, f.note, f.parent = true, n, units
				units = nil
				style = Style{}
				inNote = true
			} else {
				switch tag {
				case 'b':
					style.Bold = true
				case 'i':
					style.Italic = true
				case 'm':
					style.Mono = true
				case '+':
					style.Size += "+"
				case '-':
					style.Size += "-"
				}
			}
			stack = append(stack, f)
			i += 2
		case '}':
			if len(stack) == 0 {
				return fail(i, diag.StrayBrace)
			}
			f := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			style = f.saved
			if f.isNote {
				f.note.Text = normalize(units)
				units = append(f.parent, Unit{Kind: Mark, Style: f.saved, Note: f.note.Number})
				inNote = false
			}
		default:
			units = append(units, Unit{Kind: Char, R: c, Style: style})
		}
	}
	if len(stack) > 0 {
		return fail(stack[len(stack)-1].open, diag.UnclosedInline)
	}
	return normalize(units), nil
}
