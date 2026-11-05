package engine

import "strconv"

// log is the output buffer. Event lines carry a sequence number; blocks and
// ERR lines are raw.
type log struct {
	buf []byte
	seq int
}

func (l *log) begin(name string) {
	l.seq++
	l.buf = strconv.AppendInt(l.buf, int64(l.seq), 10)
	l.buf = append(l.buf, ' ')
	l.buf = append(l.buf, name...)
}

func (l *log) str(s string) *log {
	l.buf = append(l.buf, ' ')
	l.buf = append(l.buf, s...)
	return l
}

func (l *log) num(n int) *log {
	l.buf = append(l.buf, ' ')
	l.buf = strconv.AppendInt(l.buf, int64(n), 10)
	return l
}

// signed writes n with an explicit sign.
func (l *log) signed(n int) *log {
	l.buf = append(l.buf, ' ')
	if n >= 0 {
		l.buf = append(l.buf, '+')
	}
	l.buf = strconv.AppendInt(l.buf, int64(n), 10)
	return l
}

func (l *log) obj(oid int) *log {
	l.buf = append(l.buf, ' ', '#')
	l.buf = strconv.AppendInt(l.buf, int64(oid), 10)
	return l
}

func (l *log) cid(c int) *log {
	l.buf = append(l.buf, ' ', '~')
	l.buf = strconv.AppendInt(l.buf, int64(c), 10)
	return l
}

func (l *log) player(p Player) *log {
	l.buf = append(l.buf, ' ', 'A'+byte(p))
	return l
}

func (l *log) target(t Target) *log {
	switch t.Kind {
	case TPlayer:
		return l.player(Player(t.ID))
	case TObject:
		return l.obj(t.ID)
	}
	return l.cid(t.ID)
}

func (l *log) end() { l.buf = append(l.buf, '\n') }

// line appends a raw (non-event) line.
func (l *log) line(s string) {
	l.buf = append(l.buf, s...)
	l.buf = append(l.buf, '\n')
}
