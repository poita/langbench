// Package codec converts between protobuf wire-format bytes and the canonical
// text form described in SPEC.md, driven by a compiled schema.
//
// Decoding builds a value tree from the bytes (merging repeated occurrences
// of singular messages, appending repeated fields, skipping unknown fields
// and groups) and renders it as canonical text. Encoding parses the text into
// the same kind of tree, computes every message's encoded size in one
// bottom-up pass, and then writes the canonical bytes forward in a second.
//
// A Codec reuses internal scratch buffers between calls and therefore must
// not be used from several goroutines at once; create one Codec per
// goroutine (the Schema itself may be shared).
package codec

import (
	"errors"

	"protowire/schema"
)

// MaxDepth is the deepest nesting of messages (and groups) accepted. The
// specification promises inputs never exceed 64.
const MaxDepth = 128

// maxBuffer bounds input sizes so that string and bytes values can be kept
// as (offset, length) pairs packed into a uint64.
const maxBuffer = 1<<32 - 1

// Errors returned by Decode and Encode. They are static values so that
// rejecting a malformed request does not allocate.
var (
	ErrUnknownMessage = errors.New("codec: unknown message type")
	ErrTooLarge       = errors.New("codec: input too large")
	ErrDepth          = errors.New("codec: nesting too deep")

	// Decode errors.
	ErrTruncated = errors.New("codec: truncated data")
	ErrBadTag    = errors.New("codec: invalid tag")
	ErrBadLength = errors.New("codec: invalid length prefix")
	ErrBadGroup  = errors.New("codec: mismatched group")
	ErrBadPacked = errors.New("codec: malformed packed field")
	ErrBadUTF8   = errors.New("codec: string is not valid UTF-8")

	// Encode errors.
	ErrSyntax       = errors.New("codec: syntax error in text")
	ErrUnknownField = errors.New("codec: unknown field name")
	ErrDuplicate    = errors.New("codec: field given twice")
	ErrBadValue     = errors.New("codec: value of wrong kind or out of range")
)

// Codec encodes and decodes messages of one schema.
type Codec struct {
	schema *schema.Schema

	arena  []byte   // encode: string/bytes literal storage
	groups []uint32 // decode: open-group stack
}

// New returns a Codec for s.
func New(s *schema.Schema) *Codec { return &Codec{schema: s} }

// Schema returns the schema the Codec was created with.
func (c *Codec) Schema() *schema.Schema { return c.schema }

// Decode decodes data as the named message type and returns its canonical
// text form.
func (c *Codec) Decode(message string, data []byte) (string, error) {
	m := c.schema.Lookup(message)
	if m == nil {
		return "", ErrUnknownMessage
	}
	out, err := c.AppendDecode(nil, m, data)
	return string(out), err
}

// Encode parses text as the named message type and returns its canonical
// wire encoding.
func (c *Codec) Encode(message string, text string) ([]byte, error) {
	m := c.schema.Lookup(message)
	if m == nil {
		return nil, ErrUnknownMessage
	}
	return c.AppendEncode(nil, m, []byte(text))
}
