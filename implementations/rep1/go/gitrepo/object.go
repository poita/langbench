package gitrepo

import (
	"bytes"
	"errors"
	"fmt"
)

// ObjectType is the type of a git object.
type ObjectType uint8

// Object types.
const (
	TypeInvalid ObjectType = iota
	TypeCommit
	TypeTree
	TypeBlob
	TypeTag
)

var typeNames = [...]string{"", "commit", "tree", "blob", "tag"}

// String returns the type name used in an object's stored form.
func (t ObjectType) String() string {
	if int(t) < len(typeNames) {
		return typeNames[t]
	}
	return ""
}

func parseTypeName(b []byte) ObjectType {
	for t := TypeCommit; t <= TypeTag; t++ {
		if string(b) == typeNames[t] {
			return t
		}
	}
	return TypeInvalid
}

// Errors reported by the library. They are wrapped with context, so test
// with errors.Is.
var (
	ErrNotFound = errors.New("gitrepo: object not found")
	ErrDamaged  = errors.New("gitrepo: damaged object")
	ErrType     = errors.New("gitrepo: wrong object type")
	ErrRevision = errors.New("gitrepo: cannot resolve revision")
)

// Mode bits of tree entries.
const (
	ModeTypeMask = 0o170000
	ModeTree     = 0o040000
	ModeGitlink  = 0o160000
)

// TreeEntry is one entry of a tree object.
type TreeEntry struct {
	Mode uint32
	Name []byte
	ID   ID
}

// Type returns the object type implied by the entry's mode: tree, commit
// (a submodule) or blob.
func (e *TreeEntry) Type() ObjectType {
	switch e.Mode & ModeTypeMask {
	case ModeTree:
		return TypeTree
	case ModeGitlink:
		return TypeCommit
	}
	return TypeBlob
}

// Tree is a parsed tree object; Entries are in stored order.
type Tree struct {
	Entries []TreeEntry
}

// Lookup returns the first entry with the given name.
func (t *Tree) Lookup(name []byte) (*TreeEntry, bool) {
	for i := range t.Entries {
		if bytes.Equal(t.Entries[i].Name, name) {
			return &t.Entries[i], true
		}
	}
	return nil, false
}

func parseTree(data []byte) (*Tree, error) {
	t := &Tree{}
	for len(data) > 0 {
		sp := bytes.IndexByte(data, ' ')
		if sp <= 0 || sp > 7 {
			return nil, fmt.Errorf("%w: bad tree mode", ErrDamaged)
		}
		var mode uint32
		for _, c := range data[:sp] {
			if c < '0' || c > '7' {
				return nil, fmt.Errorf("%w: bad tree mode", ErrDamaged)
			}
			mode = mode<<3 | uint32(c-'0')
		}
		rest := data[sp+1:]
		nul := bytes.IndexByte(rest, 0)
		if nul < 0 || len(rest) < nul+1+IDSize {
			return nil, fmt.Errorf("%w: truncated tree entry", ErrDamaged)
		}
		var e TreeEntry
		e.Mode = mode
		e.Name = rest[:nul]
		copy(e.ID[:], rest[nul+1:])
		t.Entries = append(t.Entries, e)
		data = rest[nul+1+IDSize:]
	}
	return t, nil
}

// Commit is a parsed commit. Everything needed to print a log line is
// computed once at parse time.
type Commit struct {
	Tree          ID
	HasTree       bool
	Parents       []ID
	CommitterTime uint64
	AuthorName    []byte
	AuthorTime    uint64
	Subject       []byte
	// LogSuffix is "<author name> <author time> <subject>", the part of a
	// log line after the id.
	LogSuffix []byte
}

// splitHeaders splits an object payload at the first empty line into header
// lines (with continuation lines folded into their predecessor) and the
// message.
func splitHeaders(data []byte) (headers [][]byte, msg []byte) {
	pos := 0
	for pos < len(data) {
		nl := bytes.IndexByte(data[pos:], '\n')
		var line []byte
		next := len(data)
		if nl < 0 {
			line = data[pos:]
		} else {
			line = data[pos : pos+nl]
			next = pos + nl + 1
		}
		if len(line) == 0 {
			return headers, data[next:]
		}
		if line[0] == ' ' && len(headers) > 0 {
			// continuation of the previous header: ignored content-wise
			pos = next
			continue
		}
		headers = append(headers, line)
		pos = next
	}
	return headers, nil
}

// parseIdent extracts the name and timestamp from an ident line body
// ("Name <email> 123 +0000").
func parseIdent(b []byte) (name []byte, ts uint64) {
	lt := bytes.IndexByte(b, '<')
	if lt < 0 {
		return trimRight(b), 0
	}
	name = trimRight(b[:lt])
	gt := bytes.IndexByte(b[lt:], '>')
	if gt < 0 {
		return name, 0
	}
	rest := b[lt+gt+1:]
	i := 0
	for i < len(rest) && rest[i] == ' ' {
		i++
	}
	if i < len(rest) && (rest[i] == '+' || rest[i] == '-') {
		i++
	}
	for ; i < len(rest) && rest[i] >= '0' && rest[i] <= '9'; i++ {
		d := uint64(rest[i] - '0')
		if ts > (1<<64-1-d)/10 {
			ts = 1<<64 - 1
			continue
		}
		ts = ts*10 + d
	}
	return name, ts
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f'
}

func trimRight(b []byte) []byte {
	for len(b) > 0 && isSpace(b[len(b)-1]) {
		b = b[:len(b)-1]
	}
	return b
}

// subject computes the commit subject from a message.
func subject(msg []byte) []byte {
	var out []byte
	started := false
	for len(msg) > 0 {
		var line []byte
		if nl := bytes.IndexByte(msg, '\n'); nl < 0 {
			line, msg = msg, nil
		} else {
			line, msg = msg[:nl], msg[nl+1:]
		}
		line = trimRight(line)
		if len(line) == 0 {
			if started {
				break
			}
			continue
		}
		if started {
			out = append(out, ' ')
		}
		started = true
		out = append(out, line...)
	}
	return out
}

func appendUint(dst []byte, v uint64) []byte {
	var b [20]byte
	i := len(b)
	for {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
		if v == 0 {
			break
		}
	}
	return append(dst, b[i:]...)
}

func parseCommit(data []byte) (*Commit, error) {
	c := &Commit{}
	headers, msg := splitHeaders(data)
	var author, committer []byte
	var haveAuthor, haveCommitter bool
	for _, h := range headers {
		sp := bytes.IndexByte(h, ' ')
		if sp < 0 {
			continue
		}
		key, val := string(h[:sp]), h[sp+1:]
		switch key {
		case "tree":
			id, ok := parseIDBytes(val)
			if !ok {
				return nil, fmt.Errorf("%w: bad tree header", ErrDamaged)
			}
			c.Tree, c.HasTree = id, true
		case "parent":
			id, ok := parseIDBytes(val)
			if !ok {
				return nil, fmt.Errorf("%w: bad parent header", ErrDamaged)
			}
			c.Parents = append(c.Parents, id)
		case "author":
			author, haveAuthor = val, true
		case "committer":
			committer, haveCommitter = val, true
		}
	}
	if haveAuthor {
		c.AuthorName, c.AuthorTime = parseIdent(author)
	}
	if haveCommitter {
		_, c.CommitterTime = parseIdent(committer)
	}
	c.Subject = subject(msg)
	s := make([]byte, 0, len(c.AuthorName)+len(c.Subject)+22)
	s = append(s, c.AuthorName...)
	s = append(s, ' ')
	s = appendUint(s, c.AuthorTime)
	s = append(s, ' ')
	s = append(s, c.Subject...)
	c.LogSuffix = s
	return c, nil
}

// parseTagTarget returns the id named by a tag object's "object" header.
func parseTagTarget(data []byte) (ID, error) {
	headers, _ := splitHeaders(data)
	var target ID
	found := false
	for _, h := range headers {
		if bytes.HasPrefix(h, []byte("object ")) {
			id, ok := parseIDBytes(h[7:])
			if !ok {
				return target, fmt.Errorf("%w: bad tag object header", ErrDamaged)
			}
			target, found = id, true
		}
	}
	if !found {
		return target, fmt.Errorf("%w: tag without object header", ErrDamaged)
	}
	return target, nil
}
