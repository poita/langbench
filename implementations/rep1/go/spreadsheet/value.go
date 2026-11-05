package spreadsheet

import "example.com/spreadsheet/numfmt"

// Kind is the type of a Value.
type Kind uint8

// Value kinds.
const (
	Empty  Kind = iota // no content
	Number             // a finite float64
	String             // a string
	Error              // one of the error codes
)

// ErrCode identifies a spreadsheet error.
type ErrCode uint8

// Error codes.
const (
	ErrNone  ErrCode = iota
	ErrDiv0          // #DIV/0!
	ErrRef           // #REF!
	ErrCycle         // #CYCLE!
	ErrValue         // #VALUE!
)

var errText = [...]string{"", "#DIV/0!", "#REF!", "#CYCLE!", "#VALUE!"}

// String returns the error's display text, such as "#DIV/0!".
func (c ErrCode) String() string { return errText[c] }

// Value is the value of a cell: empty, a number, a string or an error.
// The zero Value is empty.
type Value struct {
	kind Kind
	err  ErrCode
	num  float64
	str  string
}

// NumberValue returns a number Value. A negative zero is normalised to zero.
func NumberValue(f float64) Value {
	if f == 0 {
		f = 0
	}
	return Value{kind: Number, num: f}
}

// StringValue returns a string Value.
func StringValue(s string) Value { return Value{kind: String, str: s} }

// ErrorValue returns an error Value.
func ErrorValue(c ErrCode) Value { return Value{kind: Error, err: c} }

// Kind reports the kind of v.
func (v Value) Kind() Kind { return v.kind }

// Number returns the number held by v (0 unless v.Kind() == Number).
func (v Value) Number() float64 { return v.num }

// Str returns the string held by v ("" unless v.Kind() == String).
func (v Value) Str() string { return v.str }

// Err returns the error code held by v (ErrNone unless v.Kind() == Error).
func (v Value) Err() ErrCode { return v.err }

// String returns the displayed form of v: strings without quotes, errors as
// their code, numbers per package numfmt, and "" for an empty value.
func (v Value) String() string {
	switch v.kind {
	case Number:
		return numfmt.Format(v.num)
	case String:
		return v.str
	case Error:
		return v.err.String()
	}
	return ""
}

// AppendTo appends the displayed form of v to dst.
func (v Value) AppendTo(dst []byte) []byte {
	switch v.kind {
	case Number:
		return numfmt.Append(dst, v.num)
	case String:
		return append(dst, v.str...)
	case Error:
		return append(dst, v.err.String()...)
	}
	return dst
}
