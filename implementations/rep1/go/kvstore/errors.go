package tessera

// ErrorKind names the way a command can fail. The string form is exactly the
// word printed after "error" in results.txt.
type ErrorKind string

// The error kinds of the command language.
const (
	ErrSyntax          ErrorKind = "syntax"
	ErrUnknownCommand  ErrorKind = "unknown-command"
	ErrBadUTF8         ErrorKind = "bad-utf8"
	ErrIntRange        ErrorKind = "int-range"
	ErrDupField        ErrorKind = "dup-field"
	ErrDepth           ErrorKind = "depth"
	ErrBadKey          ErrorKind = "bad-key"
	ErrBadPath         ErrorKind = "bad-path"
	ErrNotFound        ErrorKind = "not-found"
	ErrNoField         ErrorKind = "no-field"
	ErrNotObject       ErrorKind = "not-object"
	ErrDocTooLarge     ErrorKind = "doc-too-large"
	ErrIndexKeyTooLong ErrorKind = "index-key-too-long"
	ErrIndexExists     ErrorKind = "index-exists"
	ErrIndexMissing    ErrorKind = "index-missing"
	ErrIndexLimit      ErrorKind = "index-limit"
	ErrTxnActive       ErrorKind = "txn-active"
	ErrNoTxn           ErrorKind = "no-txn"
)

// Error is the error type returned by every failing operation of the package.
// A failed operation never modifies the database.
type Error struct {
	Kind ErrorKind
}

func (e *Error) Error() string { return string(e.Kind) }

func newErr(k ErrorKind) error { return &Error{Kind: k} }

// KindOf extracts the ErrorKind of err, or "" when err is nil or not an *Error.
func KindOf(err error) ErrorKind {
	if e, ok := err.(*Error); ok {
		return e.Kind
	}
	return ""
}
