// Package diag defines the single error type used to report an invalid
// settings file or document, together with the error codes.
package diag

import "fmt"

// Error codes reported in error.txt.
const (
	MissingDocument    = "missing-document"
	BadSyntax          = "bad-syntax"
	UnknownSetting     = "unknown-setting"
	DuplicateSetting   = "duplicate-setting"
	BadLength          = "bad-length"
	BadInteger         = "bad-integer"
	BadBoolean         = "bad-boolean"
	BadEnum            = "bad-enum"
	UnknownFont        = "unknown-font"
	UnknownPatterns    = "unknown-patterns"
	BadValue           = "bad-value"
	BadEscape          = "bad-escape"
	UnknownPlaceholder = "unknown-placeholder"
	StrayBrace         = "stray-brace"
	UnknownBlock       = "unknown-block"
	BlockNotAllowed    = "block-not-allowed"
	DuplicateTOC       = "duplicate-toc"
	UnexpectedEnd      = "unexpected-end"
	MissingEnd         = "missing-end"
	BadAttribute       = "bad-attribute"
	MissingAttribute   = "missing-attribute"
	BadAttributeValue  = "bad-attribute-value"
	CellCount          = "cell-count"
	TextNotAllowed     = "text-not-allowed"
	UnknownMeta        = "unknown-meta"
	DuplicateMeta      = "duplicate-meta"
	UnknownInline      = "unknown-inline"
	UnclosedInline     = "unclosed-inline"
	NestedFootnote     = "nested-footnote"
	FootnoteNotAllowed = "footnote-not-allowed"
)

// Error is a located input error. Line and Col are 1-based; Col counts
// Unicode scalar values.
type Error struct {
	File string
	Line int
	Col  int
	Code string
}

// Error formats the error as "<file>:<line>:<col>: <code>".
func (e *Error) Error() string {
	return fmt.Sprintf("%s:%d:%d: %s", e.File, e.Line, e.Col, e.Code)
}
