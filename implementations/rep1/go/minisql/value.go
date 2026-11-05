package minisql

import "strings"

// Kind identifies the dynamic type of a Value.
type Kind uint8

// The value kinds.
const (
	KindNull Kind = iota
	KindInteger
	KindText
	KindReal
)

// String returns the kind's name.
func (k Kind) String() string {
	switch k {
	case KindNull:
		return "NULL"
	case KindInteger:
		return "INTEGER"
	case KindText:
		return "TEXT"
	case KindReal:
		return "REAL"
	}
	return "?"
}

// Value is a single SQL value. The zero Value is NULL. Copying a Value is
// O(1) and never copies text.
type Value struct {
	kind Kind
	i    int64  // INTEGER value, or REAL value in hundredths
	s    string // TEXT value
}

// Null returns the NULL value.
func Null() Value { return Value{} }

// Int returns an INTEGER value.
func Int(i int64) Value { return Value{kind: KindInteger, i: i} }

// Text returns a TEXT value.
func Text(s string) Value { return Value{kind: KindText, s: s} }

// RealHundredths returns a REAL value equal to h/100. REAL values are only
// ever produced by AVG, which rounds to two decimal places.
func RealHundredths(h int64) Value { return Value{kind: KindReal, i: h} }

// Kind returns the value's dynamic type.
func (v Value) Kind() Kind { return v.kind }

// IsNull reports whether v is NULL.
func (v Value) IsNull() bool { return v.kind == KindNull }

// Integer returns the integer held by an INTEGER value (0 for other kinds).
func (v Value) Integer() int64 {
	if v.kind == KindInteger {
		return v.i
	}
	return 0
}

// Str returns the text held by a TEXT value ("" for other kinds).
func (v Value) Str() string { return v.s }

// Hundredths returns a REAL value scaled by 100 (0 for other kinds).
func (v Value) Hundredths() int64 {
	if v.kind == KindReal {
		return v.i
	}
	return 0
}

// String formats v the way query output does: NULL, decimal integers, raw
// text, and REAL with exactly two decimals.
func (v Value) String() string {
	var sb strings.Builder
	sb.Write(v.appendTo(nil))
	return sb.String()
}

func cmpInt(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Compare is the total order used by comparisons, ORDER BY, GROUP BY, MIN
// and MAX: NULL sorts first, then numbers (INTEGER and REAL by value), then
// TEXT by code point (bytewise on UTF-8). It returns -1, 0 or 1.
func Compare(a, b Value) int {
	if a.kind == KindNull {
		if b.kind == KindNull {
			return 0
		}
		return -1
	}
	if b.kind == KindNull {
		return 1
	}
	aText, bText := a.kind == KindText, b.kind == KindText
	if aText != bText {
		if bText {
			return -1
		}
		return 1
	}
	if aText {
		return strings.Compare(a.s, b.s)
	}
	switch {
	case a.kind == KindInteger && b.kind == KindReal:
		return cmpInt(a.i*100, b.i)
	case a.kind == KindReal && b.kind == KindInteger:
		return cmpInt(a.i, b.i*100)
	}
	return cmpInt(a.i, b.i)
}

// tri is a three-valued logic value.
type tri uint8

const (
	triFalse tri = iota
	triTrue
	triNull
)

func (v Value) truth() tri {
	switch v.kind {
	case KindNull:
		return triNull
	case KindInteger, KindReal:
		if v.i != 0 {
			return triTrue
		}
	}
	return triFalse
}

func triValue(t tri) Value {
	switch t {
	case triTrue:
		return Int(1)
	case triFalse:
		return Int(0)
	}
	return Null()
}

func boolValue(b bool) Value {
	if b {
		return Int(1)
	}
	return Int(0)
}

// appendKey appends an unambiguous, type-tagged encoding of v to buf, used to
// build hash keys for GROUP BY and joins.
func appendKey(buf []byte, v Value) []byte {
	buf = append(buf, byte(v.kind))
	switch v.kind {
	case KindInteger, KindReal:
		u := uint64(v.i)
		buf = append(buf, byte(u>>56), byte(u>>48), byte(u>>40), byte(u>>32),
			byte(u>>24), byte(u>>16), byte(u>>8), byte(u))
	case KindText:
		n := uint32(len(v.s))
		buf = append(buf, byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
		buf = append(buf, v.s...)
	}
	return buf
}
