package minisql

import "strconv"

// appendTo appends the textual form of v used in query output.
func (v Value) appendTo(buf []byte) []byte {
	switch v.kind {
	case KindNull:
		return append(buf, "NULL"...)
	case KindInteger:
		return strconv.AppendInt(buf, v.i, 10)
	case KindText:
		return append(buf, v.s...)
	case KindReal:
		h := v.i
		if h < 0 {
			buf = append(buf, '-')
			h = -h
		}
		buf = strconv.AppendInt(buf, h/100, 10)
		buf = append(buf, '.', byte('0'+h/10%10), byte('0'+h%10))
		return buf
	}
	return buf
}

// AppendTo appends the result in the command-line output format: one
// tab-separated line per row followed by a "-- N rows" line.
func (r *Result) AppendTo(buf []byte) []byte {
	for _, row := range r.Rows {
		for i, v := range row {
			if i > 0 {
				buf = append(buf, '\t')
			}
			buf = v.appendTo(buf)
		}
		buf = append(buf, '\n')
	}
	buf = append(buf, "-- "...)
	buf = strconv.AppendInt(buf, int64(len(r.Rows)), 10)
	return append(buf, " rows\n"...)
}
