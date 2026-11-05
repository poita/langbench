package sqlitefile

import "bytes"

// Kind is the storage class of a Value.
type Kind uint8

// Storage classes, in the order SQLite sorts them.
const (
	KindNull Kind = iota
	KindInteger
	KindReal
	KindText
	KindBlob
)

// String returns the lower-case name of the storage class.
func (k Kind) String() string {
	switch k {
	case KindNull:
		return "null"
	case KindInteger:
		return "integer"
	case KindReal:
		return "real"
	case KindText:
		return "text"
	case KindBlob:
		return "blob"
	}
	return "invalid"
}

// Value is a single SQLite value. Only the field matching Kind is meaningful:
// I for KindInteger, F for KindReal, and B for KindText (UTF-8) and KindBlob.
//
// Values returned by the scanning internals may alias the database buffer; the
// public API always hands out values that are safe to retain, but callers must
// not modify the bytes in B.
type Value struct {
	Kind Kind
	I    int64
	F    float64
	B    []byte
}

// Null returns the NULL value.
func Null() Value { return Value{} }

// Int returns an INTEGER value.
func Int(i int64) Value { return Value{Kind: KindInteger, I: i} }

// Real returns a REAL value.
func Real(f float64) Value { return Value{Kind: KindReal, F: f} }

// Text returns a TEXT value holding s.
func Text(s string) Value { return Value{Kind: KindText, B: []byte(s)} }

// Blob returns a BLOB value holding a copy of b.
func Blob(b []byte) Value { return Value{Kind: KindBlob, B: append([]byte{}, b...)} }

// IsNull reports whether v is NULL.
func (v Value) IsNull() bool { return v.Kind == KindNull }

// String returns v as the command-line tool prints it (see AppendValue).
func (v Value) String() string { return string(AppendValue(nil, v)) }

// Compare orders two values per the SQLite rules with BINARY collation: NULL
// sorts before numbers, numbers before TEXT, TEXT before BLOB. Integers compare
// exactly; an integer against a real is widened to float64. It returns -1, 0
// or +1.
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
		if a.Kind == KindInteger && b.Kind == KindInteger {
			switch {
			case a.I < b.I:
				return -1
			case a.I > b.I:
				return 1
			}
			return 0
		}
		return cmpFloat(a.num(), b.num())
	}
	return bytes.Compare(a.B, b.B)
}

func rank(k Kind) int {
	switch k {
	case KindNull:
		return 0
	case KindInteger, KindReal:
		return 1
	case KindText:
		return 2
	}
	return 3
}

func (v Value) num() float64 {
	if v.Kind == KindInteger {
		return float64(v.I)
	}
	return v.F
}

func cmpFloat(a, b float64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Affinity is a column's type affinity.
type Affinity uint8

// Column affinities.
const (
	AffinityBlob Affinity = iota
	AffinityText
	AffinityNumeric
	AffinityInteger
	AffinityReal
)

// String returns the upper-case affinity name.
func (a Affinity) String() string {
	switch a {
	case AffinityBlob:
		return "BLOB"
	case AffinityText:
		return "TEXT"
	case AffinityNumeric:
		return "NUMERIC"
	case AffinityInteger:
		return "INTEGER"
	case AffinityReal:
		return "REAL"
	}
	return "?"
}

// AffinityOf derives the affinity of a declared column type using SQLite's five
// rules, applied in order.
func AffinityOf(declType string) Affinity {
	t := asciiUpper(declType)
	has := func(s string) bool { return bytes.Contains([]byte(t), []byte(s)) }
	switch {
	case has("INT"):
		return AffinityInteger
	case has("CHAR"), has("CLOB"), has("TEXT"):
		return AffinityText
	case has("BLOB"), t == "":
		return AffinityBlob
	case has("REAL"), has("FLOA"), has("DOUB"):
		return AffinityReal
	}
	return AffinityNumeric
}

func asciiUpper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}

// ApplyAffinity converts a query literal before it is compared with a column of
// the given affinity. TEXT columns turn numeric literals into text; numeric
// columns turn numeric-looking text into numbers. Everything else is returned
// unchanged.
func ApplyAffinity(v Value, aff Affinity) Value {
	switch aff {
	case AffinityText:
		if v.Kind == KindInteger || v.Kind == KindReal {
			return Value{Kind: KindText, B: AppendValue(nil, v)}
		}
	case AffinityInteger, AffinityReal, AffinityNumeric:
		if v.Kind == KindText {
			if n, ok := parseNumericText(v.B); ok {
				return n
			}
		}
	}
	return v
}

// parseNumericText parses b as a numeric constant: optional surrounding
// spaces/tabs, then [+-]? (digits [. digits?] | . digits) ([eE][+-]?digits)?.
func parseNumericText(b []byte) (Value, bool) {
	for len(b) > 0 && (b[0] == ' ' || b[0] == '\t') {
		b = b[1:]
	}
	for len(b) > 0 && (b[len(b)-1] == ' ' || b[len(b)-1] == '\t') {
		b = b[:len(b)-1]
	}
	i := 0
	if i < len(b) && (b[i] == '+' || b[i] == '-') {
		i++
	}
	intDigits := 0
	for i < len(b) && isDigit(b[i]) {
		i++
		intDigits++
	}
	isReal := false
	if i < len(b) && b[i] == '.' {
		isReal = true
		i++
		frac := 0
		for i < len(b) && isDigit(b[i]) {
			i++
			frac++
		}
		if intDigits == 0 && frac == 0 {
			return Value{}, false
		}
	} else if intDigits == 0 {
		return Value{}, false
	}
	if i < len(b) && (b[i] == 'e' || b[i] == 'E') {
		isReal = true
		i++
		if i < len(b) && (b[i] == '+' || b[i] == '-') {
			i++
		}
		exp := 0
		for i < len(b) && isDigit(b[i]) {
			i++
			exp++
		}
		if exp == 0 {
			return Value{}, false
		}
	}
	if i != len(b) {
		return Value{}, false
	}
	return numberFromText(string(b), isReal)
}

// numberFromText converts validated numeric text. Integers that fit in int64
// stay integers; everything else becomes a float64.
func numberFromText(s string, isReal bool) (Value, bool) {
	if !isReal {
		if n, ok := parseInt64(s); ok {
			return Int(n), true
		}
	}
	f, ok := parseFloat(s)
	if !ok {
		return Value{}, false
	}
	return Real(f), true
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// widenReal converts an integer to a float64, leaving other kinds untouched.
func widenReal(v Value) Value {
	if v.Kind == KindInteger {
		return Real(float64(v.I))
	}
	return v
}
