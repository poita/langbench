// Package schema defines the compiled form of a protowire message schema and
// a parser for the schema language.
//
// A Schema is immutable after Parse returns and is safe for concurrent use.
package schema

import (
	"protowire/wire"
)

// Kind is the type of a field: one of the scalar types or a message.
type Kind uint8

// Field kinds.
const (
	Int32 Kind = iota
	Int64
	Uint32
	Uint64
	Sint32
	Sint64
	Bool
	Fixed32
	Fixed64
	Sfixed32
	Sfixed64
	String
	BytesKind
	Message
)

var kindNames = [...]string{
	Int32: "int32", Int64: "int64", Uint32: "uint32", Uint64: "uint64",
	Sint32: "sint32", Sint64: "sint64", Bool: "bool",
	Fixed32: "fixed32", Fixed64: "fixed64", Sfixed32: "sfixed32", Sfixed64: "sfixed64",
	String: "string", BytesKind: "bytes", Message: "message",
}

// String returns the schema-language name of the kind.
func (k Kind) String() string { return kindNames[k] }

// Signed reports whether integer values of this kind print as signed.
func (k Kind) Signed() bool {
	switch k {
	case Int32, Int64, Sint32, Sint64, Sfixed32, Sfixed64:
		return true
	}
	return false
}

// IsNumeric reports whether the kind is a scalar number or bool, i.e. a
// kind that a repeated field may carry packed.
func (k Kind) IsNumeric() bool { return k < String }

// IsBytesLike reports whether values of the kind are byte strings
// (string or bytes).
func (k Kind) IsBytesLike() bool { return k == String || k == BytesKind }

// WireType returns the natural wire type of an element of this kind.
func (k Kind) WireType() int {
	switch k {
	case Int32, Int64, Uint32, Uint64, Sint32, Sint64, Bool:
		return wire.Varint
	case Fixed32, Sfixed32:
		return wire.Fixed32
	case Fixed64, Sfixed64:
		return wire.Fixed64
	}
	return wire.Bytes
}

// Field describes one field of a message.
type Field struct {
	Name     string
	Number   uint32
	Kind     Kind
	Repeated bool
	// Message is the index (into Schema.Messages) of the field's message
	// type; meaningful only when Kind == Message.
	Message int
	// WireType is the wire type of one element of the field's kind.
	WireType int
	// Tag is the precomputed varint tag used when encoding the field. A
	// repeated numeric field is always encoded packed, so its tag carries
	// wire type 2.
	Tag []byte
}

// MessageType describes a message type. Fields are sorted by field number;
// a field's index in Fields is its slot number in value trees.
type MessageType struct {
	Name   string
	Fields []Field

	numbers []uint32       // Fields[i].Number, for binary search
	byName  map[string]int // field name -> index in Fields
}

// FieldByNumber returns the index of the field with the given number, or -1.
func (m *MessageType) FieldByNumber(number uint32) int {
	lo, hi := 0, len(m.numbers)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if m.numbers[mid] < number {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(m.numbers) && m.numbers[lo] == number {
		return lo
	}
	return -1
}

// FieldByName returns the index of the field with the given name, or -1.
// It does not allocate.
func (m *MessageType) FieldByName(name []byte) int {
	if i, ok := m.byName[string(name)]; ok {
		return i
	}
	return -1
}

// Schema is a set of compiled message types.
type Schema struct {
	Messages []MessageType
	byName   map[string]int
}

// Lookup returns the message type with the given name, or nil.
func (s *Schema) Lookup(name string) *MessageType {
	if i, ok := s.byName[name]; ok {
		return &s.Messages[i]
	}
	return nil
}

// LookupBytes is like Lookup but takes the name as a byte slice without
// allocating.
func (s *Schema) LookupBytes(name []byte) *MessageType {
	if i, ok := s.byName[string(name)]; ok {
		return &s.Messages[i]
	}
	return nil
}
