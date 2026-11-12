package spreadsheet

// Kind classifies a Value.
type Kind uint8

// The kinds of value.
const (
	// KindEmpty is the value of a cell that has no content.
	KindEmpty Kind = iota
	// KindNumber is a finite IEEE-754 double.
	KindNumber
	// KindString is a text value.
	KindString
	// KindError is one of the ErrorCode errors.
	KindError
)

// ErrorCode identifies a spreadsheet error.
type ErrorCode uint8

// The error codes a cell can evaluate to.
const (
	ErrNone  ErrorCode = iota
	ErrDiv0            // #DIV/0!
	ErrRef             // #REF!
	ErrCycle           // #CYCLE!
	ErrValue           // #VALUE!
)

// String returns the displayed form of the error code.
func (e ErrorCode) String() string {
	switch e {
	case ErrDiv0:
		return "#DIV/0!"
	case ErrRef:
		return "#REF!"
	case ErrCycle:
		return "#CYCLE!"
	case ErrValue:
		return "#VALUE!"
	}
	return ""
}

// Value is the result of evaluating a cell. The zero Value is empty.
type Value struct {
	kind Kind
	num  float64
	str  string
	err  ErrorCode
}

// Number returns a number Value.
func Number(f float64) Value { return Value{kind: KindNumber, num: f} }

// String returns a string Value.
func String(s string) Value { return Value{kind: KindString, str: s} }

// Error returns an error Value.
func Error(e ErrorCode) Value { return Value{kind: KindError, err: e} }

// Kind reports the kind of the value.
func (v Value) Kind() Kind { return v.kind }

// IsEmpty reports whether the value is empty.
func (v Value) IsEmpty() bool { return v.kind == KindEmpty }

// Num returns the number held by a KindNumber value, else 0.
func (v Value) Num() float64 { return v.num }

// Text returns the string held by a KindString value, else "".
func (v Value) Text() string { return v.str }

// Err returns the error code of a KindError value, else ErrNone.
func (v Value) Err() ErrorCode { return v.err }

// String returns the displayed form of the value: the string itself, the
// error code, the formatted number (see FormatNumber), or "" when empty.
func (v Value) String() string {
	switch v.kind {
	case KindNumber:
		return FormatNumber(v.num)
	case KindString:
		return v.str
	case KindError:
		return v.err.String()
	}
	return ""
}
