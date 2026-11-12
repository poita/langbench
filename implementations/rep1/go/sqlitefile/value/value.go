// Package value defines the SQLite value model used by the rest of the
// library: the five storage classes, the total ordering between values,
// column type affinity, and the textual output format.
package value

import (
	"strconv"
	"strings"
)

// Kind is a SQLite storage class.
type Kind uint8

// The five storage classes, in the order they sort.
const (
	Null Kind = iota
	Integer
	Real
	Text
	Blob
)

func (k Kind) String() string {
	switch k {
	case Null:
		return "NULL"
	case Integer:
		return "INTEGER"
	case Real:
		return "REAL"
	case Text:
		return "TEXT"
	case Blob:
		return "BLOB"
	}
	return "?"
}

// Value is a single SQLite value. Only the field matching Kind is meaningful:
// Int for Integer, Real for Real, and Str for Text and Blob (a Blob holds its
// raw bytes in Str).
type Value struct {
	Kind Kind
	Int  int64
	Real float64
	Str  string
}

// NullValue is the NULL value.
var NullValue = Value{}

// NewInt returns an INTEGER value.
func NewInt(i int64) Value { return Value{Kind: Integer, Int: i} }

// NewReal returns a REAL value.
func NewReal(f float64) Value { return Value{Kind: Real, Real: f} }

// NewText returns a TEXT value.
func NewText(s string) Value { return Value{Kind: Text, Str: s} }

// NewBlob returns a BLOB value holding a copy of b.
func NewBlob(b []byte) Value { return Value{Kind: Blob, Str: string(b)} }

// IsNull reports whether v is NULL.
func (v Value) IsNull() bool { return v.Kind == Null }

// IsNumber reports whether v is an INTEGER or a REAL.
func (v Value) IsNumber() bool { return v.Kind == Integer || v.Kind == Real }

func (v Value) float() float64 {
	if v.Kind == Integer {
		return float64(v.Int)
	}
	return v.Real
}

func rank(k Kind) int {
	switch k {
	case Null:
		return 0
	case Integer, Real:
		return 1
	case Text:
		return 2
	}
	return 3
}

// Compare is the three-way comparison of two values (SQLite's BINARY
// collation ordering): NULL < numbers < TEXT < BLOB. Numbers compare by
// mathematical value, two INTEGERs exactly, an INTEGER against a REAL after
// widening to a double. TEXT and BLOB compare bytewise. It returns -1, 0 or 1.
func Compare(a, b Value) int {
	ra, rb := rank(a.Kind), rank(b.Kind)
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
		if a.Kind == Integer && b.Kind == Integer {
			switch {
			case a.Int < b.Int:
				return -1
			case a.Int > b.Int:
				return 1
			}
			return 0
		}
		x, y := a.float(), b.float()
		switch {
		case x < y:
			return -1
		case x > y:
			return 1
		}
		return 0
	}
	return strings.Compare(a.Str, b.Str)
}

// String formats v the way the sqlite3 shell prints it in list mode with
// "-nullvalue NULL" and blobs hex-encoded.
func (v Value) String() string {
	switch v.Kind {
	case Null:
		return "NULL"
	case Integer:
		return strconv.FormatInt(v.Int, 10)
	case Real:
		return FormatReal(v.Real)
	case Text:
		return v.Str
	}
	const hex = "0123456789ABCDEF"
	out := make([]byte, 0, 2*len(v.Str))
	for i := 0; i < len(v.Str); i++ {
		out = append(out, hex[v.Str[i]>>4], hex[v.Str[i]&15])
	}
	return string(out)
}

// FormatReal formats a finite float like C's "%.15g", but with ".0" appended
// to a mantissa that has no decimal point, and zero (of either sign) printed
// as "0.0".
func FormatReal(f float64) string {
	if f == 0 {
		return "0.0"
	}
	s := strconv.FormatFloat(f, 'g', 15, 64)
	mant, exp := s, ""
	if i := strings.IndexByte(s, 'e'); i >= 0 {
		mant, exp = s[:i], s[i:]
	}
	if !strings.Contains(mant, ".") {
		mant += ".0"
	}
	return mant + exp
}
