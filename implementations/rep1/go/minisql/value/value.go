// Package value defines the dynamically typed values stored in and computed
// by a minisql database, together with the total order used to compare them.
//
// A Value is NULL, a signed 64-bit INTEGER, a TEXT string, or a REAL. REAL
// values are only ever produced by AVG and carry exactly two decimal places;
// they are represented internally as a count of hundredths.
package value

import (
	"strconv"
)

// Kind identifies the dynamic type of a Value.
type Kind uint8

// The kinds of value. The zero Value is NULL.
const (
	KindNull Kind = iota
	KindInt
	KindReal
	KindText
)

// Value is an immutable dynamically typed SQL value. The zero Value is NULL.
type Value struct {
	kind Kind
	n    int64 // integer, or hundredths for KindReal
	s    string
}

// Null returns the NULL value.
func Null() Value { return Value{} }

// Int returns the INTEGER value n.
func Int(n int64) Value { return Value{kind: KindInt, n: n} }

// Text returns the TEXT value s.
func Text(s string) Value { return Value{kind: KindText, s: s} }

// RealHundredths returns the REAL value h/100.
func RealHundredths(h int64) Value { return Value{kind: KindReal, n: h} }

// Bool returns INTEGER 1 for true and 0 for false.
func Bool(b bool) Value {
	if b {
		return Int(1)
	}
	return Int(0)
}

// Kind reports the dynamic type of v.
func (v Value) Kind() Kind { return v.kind }

// IsNull reports whether v is NULL.
func (v Value) IsNull() bool { return v.kind == KindNull }

// AsInt returns the integer held by an INTEGER value (0 for other kinds).
func (v Value) AsInt() int64 {
	if v.kind == KindInt {
		return v.n
	}
	return 0
}

// AsText returns the string held by a TEXT value ("" for other kinds).
func (v Value) AsText() string { return v.s }

// Hundredths returns the number of hundredths held by a REAL value.
func (v Value) Hundredths() int64 {
	if v.kind == KindReal {
		return v.n
	}
	return 0
}

// String renders v the way a SELECT prints it: NULL as "NULL", integers in
// decimal, text verbatim and reals with exactly two decimals.
func (v Value) String() string {
	switch v.kind {
	case KindInt:
		return strconv.FormatInt(v.n, 10)
	case KindText:
		return v.s
	case KindReal:
		return formatHundredths(v.n)
	}
	return "NULL"
}

func formatHundredths(h int64) string {
	var buf [24]byte
	b := buf[:0]
	u := uint64(h)
	if h < 0 {
		b = append(b, '-')
		u = -u
	}
	b = strconv.AppendUint(b, u/100, 10)
	b = append(b, '.', byte('0'+u%100/10), byte('0'+u%10))
	return string(b)
}

// Truth interprets v in boolean context. known is false for NULL (unknown);
// otherwise truth is true for any non-zero number. Text is treated as false.
func (v Value) Truth() (truth, known bool) {
	switch v.kind {
	case KindInt, KindReal:
		return v.n != 0, true
	case KindText:
		return false, true
	}
	return false, false
}

// IsTrue reports whether v is definitely true (NULL and 0 are not).
func (v Value) IsTrue() bool {
	t, k := v.Truth()
	return t && k
}

// Compare imposes the total order used for comparison, sorting, grouping,
// MIN and MAX: NULL is smallest, then numbers (INTEGER and REAL compared by
// numeric value), then TEXT compared bytewise as UTF-8 (which is code point
// order). It returns -1, 0 or +1.
func Compare(a, b Value) int {
	ra, rb := rank(a.kind), rank(b.kind)
	if ra != rb {
		if ra < rb {
			return -1
		}
		return 1
	}
	switch ra {
	case 0:
		return 0
	case 1:
		return compareNumbers(a, b)
	}
	return compareStrings(a.s, b.s)
}

func rank(k Kind) int {
	switch k {
	case KindNull:
		return 0
	case KindInt, KindReal:
		return 1
	}
	return 2
}

func compareStrings(a, b string) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
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

func compareNumbers(a, b Value) int {
	switch {
	case a.kind == KindInt && b.kind == KindInt, a.kind == KindReal && b.kind == KindReal:
		return cmpInt(a.n, b.n)
	case a.kind == KindInt:
		return compareIntReal(a.n, b.n)
	}
	return -compareIntReal(b.n, a.n)
}

// compareIntReal compares the integer n with the real h/100 without
// overflowing, by splitting h into its whole part and fraction.
func compareIntReal(n, h int64) int {
	q, r := h/100, h%100
	if c := cmpInt(n, q); c != 0 {
		return c
	}
	return cmpInt(0, r)
}

// Avg returns the REAL average sum/count rounded to two decimal places, half
// away from zero. count must be positive.
func Avg(sum, count int64) Value {
	abs := sum
	if abs < 0 {
		abs = -abs
	}
	h := (200*abs + count) / (2 * count)
	if sum < 0 {
		h = -h
	}
	return RealHundredths(h)
}
