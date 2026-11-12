// Package object defines git's object types and parses the three structured
// kinds (commits, trees and tags) from their raw payloads.
//
// All byte strings (names, messages) are kept as opaque bytes and are never
// reinterpreted as text.
package object

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"

	"gitrepo/sha1"
)

// ErrMalformed is wrapped by every error returned for a payload that does not
// follow the object format.
var ErrMalformed = errors.New("malformed object")

func malformed(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrMalformed, fmt.Sprintf(format, args...))
}

// Type is the kind of a git object.
type Type uint8

// The four object types.
const (
	Invalid Type = iota
	Commit
	Tree
	Blob
	Tag
)

var typeNames = [...]string{Invalid: "invalid", Commit: "commit", Tree: "tree", Blob: "blob", Tag: "tag"}

// String returns the type's name as it appears in an object header.
func (t Type) String() string {
	if int(t) < len(typeNames) {
		return typeNames[t]
	}
	return "invalid"
}

// ParseType converts a type name ("commit", "tree", "blob", "tag") to a Type.
func ParseType(name []byte) (Type, bool) {
	switch string(name) {
	case "commit":
		return Commit, true
	case "tree":
		return Tree, true
	case "blob":
		return Blob, true
	case "tag":
		return Tag, true
	}
	return Invalid, false
}

// IDSize is the length of an object id in bytes.
const IDSize = sha1.Size

// ID is an object id: the SHA-1 of the object's stored form.
type ID [IDSize]byte

// String returns the id as 40 lowercase hexadecimal digits.
func (id ID) String() string { return hex.EncodeToString(id[:]) }

// ParseID parses exactly 40 hexadecimal digits (either case).
func ParseID(s string) (ID, error) {
	var id ID
	if len(s) != 2*IDSize {
		return id, fmt.Errorf("object id %q: want %d hex digits", s, 2*IDSize)
	}
	if _, err := hex.Decode(id[:], []byte(s)); err != nil {
		return id, fmt.Errorf("object id %q: %w", s, err)
	}
	return id, nil
}

// Object is a fully read object: its type and its payload.
type Object struct {
	Type Type
	Data []byte
}

// Hash computes the id of an object of type t with payload data: the SHA-1 of
// "<type> <size>\0<payload>".
func Hash(t Type, data []byte) ID {
	d := sha1.New()
	d.WriteString(t.String())
	d.WriteString(" ")
	d.WriteString(strconv.Itoa(len(data)))
	d.Write([]byte{0})
	d.Write(data)
	var id ID
	copy(id[:], d.Sum(nil))
	return id
}

// ID returns the object's id, computed from its content.
func (o *Object) ID() ID { return Hash(o.Type, o.Data) }

const whitespace = " \t\r\n\v\f"

func trimRight(b []byte) []byte {
	for len(b) > 0 && indexByte(whitespace, b[len(b)-1]) >= 0 {
		b = b[:len(b)-1]
	}
	return b
}

func indexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}
