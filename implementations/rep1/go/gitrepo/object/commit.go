package object

import "bytes"

// Ident is the parsed form of an author, committer or tagger line.
type Ident struct {
	Name []byte // everything before the first '<', trailing whitespace removed
	When uint64 // seconds since the epoch; 0 if absent
}

// ParseIdent parses the value of an ident header, e.g.
// "Ada Lovelace <ada@example.com> 1400003600 +0000".
func ParseIdent(v []byte) Ident {
	lt := bytes.IndexByte(v, '<')
	if lt < 0 {
		return Ident{Name: trimRight(v)}
	}
	id := Ident{Name: trimRight(v[:lt])}
	gt := bytes.IndexByte(v[lt:], '>')
	if gt < 0 {
		return id
	}
	rest := v[lt+gt+1:]
	for len(rest) > 0 && rest[0] == ' ' {
		rest = rest[1:]
	}
	if len(rest) > 0 && (rest[0] == '+' || rest[0] == '-') {
		rest = rest[1:]
	}
	var n uint64
	for _, c := range rest {
		if c < '0' || c > '9' {
			break
		}
		d := uint64(c - '0')
		if n > (1<<64-1-d)/10 { // saturate rather than overflow
			n = 1<<64 - 1
			break
		}
		n = n*10 + d
	}
	id.When = n
	return id
}

// CommitObject is a parsed commit.
type CommitObject struct {
	Tree      ID
	Parents   []ID
	Author    Ident
	Committer Ident
	Message   []byte // everything after the first empty line
}

// headers splits a commit or tag payload into its header block and message
// and calls fn for every header (key, value) in order. Continuation lines
// (starting with a space) belong to the previous header and are skipped.
func headers(data []byte, fn func(key, value []byte) error) (message []byte, err error) {
	for len(data) > 0 {
		var line []byte
		if nl := bytes.IndexByte(data, '\n'); nl >= 0 {
			line, data = data[:nl], data[nl+1:]
		} else {
			line, data = data, nil
		}
		if len(line) == 0 {
			return data, nil
		}
		if line[0] == ' ' {
			continue
		}
		key, value := line, []byte(nil)
		if sp := bytes.IndexByte(line, ' '); sp >= 0 {
			key, value = line[:sp], line[sp+1:]
		}
		if err := fn(key, value); err != nil {
			return nil, err
		}
	}
	return nil, nil
}

func parseHexID(v []byte) (ID, error) {
	id, err := ParseID(string(v))
	if err != nil {
		return id, malformed("bad object id %q", v)
	}
	return id, nil
}

// ParseCommit parses a commit payload. When a header repeats the last
// occurrence wins, except for "parent", where every occurrence counts.
func ParseCommit(data []byte) (*CommitObject, error) {
	c := &CommitObject{}
	haveTree := false
	msg, err := headers(data, func(key, value []byte) (err error) {
		switch string(key) {
		case "tree":
			c.Tree, err = parseHexID(value)
			haveTree = err == nil
		case "parent":
			var p ID
			if p, err = parseHexID(value); err == nil {
				c.Parents = append(c.Parents, p)
			}
		case "author":
			c.Author = ParseIdent(value)
		case "committer":
			c.Committer = ParseIdent(value)
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	if !haveTree {
		return nil, malformed("commit without tree")
	}
	c.Message = msg
	return c, nil
}

// Subject returns the commit's subject line: the first paragraph of the
// message with trailing whitespace stripped from every line, lines joined by
// single spaces.
func (c *CommitObject) Subject() []byte { return Subject(c.Message) }

// Subject computes the subject of a commit message. Leading blank lines are
// skipped; the subject runs until the next blank line (a line that is empty
// once trailing whitespace is stripped), and its lines are joined with a
// single space.
func Subject(msg []byte) []byte {
	var out []byte
	started := false
	for len(msg) > 0 {
		var line []byte
		if nl := bytes.IndexByte(msg, '\n'); nl >= 0 {
			line, msg = msg[:nl], msg[nl+1:]
		} else {
			line, msg = msg, nil
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

// TagObject is a parsed annotated tag.
type TagObject struct {
	Target ID     // the "object" header
	Type   []byte // the "type" header, as written
	Name   []byte // the "tag" header
	Tagger Ident
	// Message is everything after the first empty line.
	Message []byte
}

// ParseTag parses an annotated tag payload. The last occurrence of a repeated
// header wins. A tag without a valid "object" header is malformed.
func ParseTag(data []byte) (*TagObject, error) {
	t := &TagObject{}
	haveObj := false
	msg, err := headers(data, func(key, value []byte) (err error) {
		switch string(key) {
		case "object":
			t.Target, err = parseHexID(value)
			haveObj = err == nil
		case "type":
			t.Type = value
		case "tag":
			t.Name = value
		case "tagger":
			t.Tagger = ParseIdent(value)
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	if !haveObj {
		return nil, malformed("tag without object")
	}
	t.Message = msg
	return t, nil
}
