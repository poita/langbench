// Package kverr defines the error kinds a Tessera command can fail with.
//
// Every failing command reports exactly one kind; the kind's name is the text
// printed after "error " in a result block.
package kverr

import "errors"

// Error is a command failure identified by its kind.
type Error struct {
	Kind string
}

// Error returns the kind name, e.g. "not-found".
func (e *Error) Error() string { return e.Kind }

func mk(kind string) *Error { return &Error{Kind: kind} }

// The error kinds of the command language.
var (
	Syntax          = mk("syntax")
	UnknownCommand  = mk("unknown-command")
	BadUTF8         = mk("bad-utf8")
	IntRange        = mk("int-range")
	DupField        = mk("dup-field")
	Depth           = mk("depth")
	BadKey          = mk("bad-key")
	BadPath         = mk("bad-path")
	NotFound        = mk("not-found")
	NoField         = mk("no-field")
	NotObject       = mk("not-object")
	DocTooLarge     = mk("doc-too-large")
	IndexKeyTooLong = mk("index-key-too-long")
	IndexExists     = mk("index-exists")
	IndexMissing    = mk("index-missing")
	IndexLimit      = mk("index-limit")
	TxnActive       = mk("txn-active")
	NoTxn           = mk("no-txn")
)

// KindOf returns the kind name of err, or "" if err is nil or is not an *Error.
func KindOf(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return e.Kind
	}
	return ""
}
