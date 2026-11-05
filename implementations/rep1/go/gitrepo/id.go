// Package gitrepo reads a git repository straight off disk: loose objects,
// packfiles (with OFS_DELTA and REF_DELTA reconstruction), refs, revision
// syntax, commit history, trees and tree diffs.
//
// A Repository is opened once and keeps everything it decodes for its whole
// lifetime, so repeated queries are cheap. It never invokes git and never
// writes to the repository.
//
// The package is split by responsibility:
//
//	id.go        object ids
//	store.go     the object store (loose objects, packs, caches)
//	pack.go      pack index / packfile access and delta application
//	object.go    parsed commits, trees and tags
//	refs.go      HEAD, loose refs and packed-refs
//	rev.go       revision syntax and peeling
//	log.go       history walking
//	tree.go      tree listing and diffs
//	quote.go     git path quoting
//	exec.go      the line-oriented query language used by the CLI
//
// A Repository is not safe for concurrent use.
package gitrepo

import (
	"encoding/hex"
	"errors"
)

// IDSize is the length of an object id in bytes.
const IDSize = 20

// ID is a SHA-1 object id.
type ID [IDSize]byte

// ErrBadID is returned by ParseID for malformed input.
var ErrBadID = errors.New("gitrepo: malformed object id")

const hexDigits = "0123456789abcdef"

// ParseID parses exactly 40 hexadecimal digits (either case).
func ParseID(s string) (ID, error) {
	var id ID
	if len(s) != 2*IDSize {
		return id, ErrBadID
	}
	if _, err := hex.Decode(id[:], []byte(s)); err != nil {
		return id, ErrBadID
	}
	return id, nil
}

// String returns the id as 40 lowercase hexadecimal digits.
func (id ID) String() string {
	var b [2 * IDSize]byte
	return string(id.appendHex(b[:0]))
}

// IsZero reports whether the id is all zero bytes.
func (id ID) IsZero() bool { return id == ID{} }

func (id ID) appendHex(dst []byte) []byte {
	for _, c := range id {
		dst = append(dst, hexDigits[c>>4], hexDigits[c&15])
	}
	return dst
}

// hexVal returns the value of a hex digit or -1.
func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// parseIDBytes parses 40 hex digits from b (either case).
func parseIDBytes(b []byte) (ID, bool) {
	var id ID
	if len(b) != 2*IDSize {
		return id, false
	}
	for i := 0; i < IDSize; i++ {
		h, l := hexVal(b[2*i]), hexVal(b[2*i+1])
		if h < 0 || l < 0 {
			return id, false
		}
		id[i] = byte(h<<4 | l)
	}
	return id, true
}
