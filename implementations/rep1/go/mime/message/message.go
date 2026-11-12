// Package message parses a raw email message into a tree of MIME parts and
// selects its text and HTML bodies and its attachments.
package message

import (
	"bytes"
	"strings"

	"example.com/mime/address"
	"example.com/mime/charset"
	"example.com/mime/date"
	"example.com/mime/header"
	"example.com/mime/transfer"
)

// Kind says how a part is structured.
type Kind int

const (
	// Leaf parts carry decoded content.
	Leaf Kind = iota
	// Multipart parts are containers split by a boundary.
	Multipart
	// MessageContainer parts (message/rfc822) hold one embedded message.
	MessageContainer
)

// Role is the part's role in the message.
type Role int

const (
	// NoRole is the role of containers.
	NoRole Role = iota
	// RoleText marks the selected plain-text body.
	RoleText
	// RoleHTML marks the selected HTML body.
	RoleHTML
	// RoleAttachment marks every other leaf.
	RoleAttachment
)

func (r Role) String() string {
	switch r {
	case RoleText:
		return "text"
	case RoleHTML:
		return "html"
	case RoleAttachment:
		return "attachment"
	}
	return ""
}

// Part is one node of the MIME tree.
type Part struct {
	Index  int // pre-order number; the message itself is 0
	Depth  int
	Kind   Kind
	Fields header.Fields

	Type, Subtype string // lower case
	Encoding      string // Content-Transfer-Encoding token
	// Charset is the normalised charset name; it is set only for text/*.
	Charset string

	HasDisposition bool
	Disposition    string
	Filename       string
	HasFilename    bool

	Boundary string // multipart containers
	Preamble int    // byte length of the preamble
	Epilogue int    // byte length of the epilogue, or -1 when absent

	Children []*Part
	Content  []byte // leaves: decoded content
	Role     Role
}

// IsText reports whether the part has a text/* type.
func (p *Part) IsText() bool { return p.Type == "text" }

// MediaType returns "type/subtype".
func (p *Part) MediaType() string { return p.Type + "/" + p.Subtype }

// Text returns the content of a text/* leaf decoded with its charset.
func (p *Part) Text() string { return charset.Decode(p.Content, p.Charset) }

// Message is a parsed message.
type Message struct {
	// Size is the byte length of the message as given to Parse.
	Size int
	Root *Part
	// Parts lists every part in pre-order.
	Parts []*Part
	// TextBody and HTMLBody are the selected bodies, or nil.
	TextBody, HTMLBody *Part
	// Attachments lists the remaining leaves in part-index order.
	Attachments []*Part
}

// Fields returns the message's header fields.
func (m *Message) Fields() header.Fields { return m.Root.Fields }

// Addresses returns every address of the header fields called name (lower
// case), in order.
func (m *Message) Addresses(name string) []address.Address {
	var out []address.Address
	for _, f := range m.Root.Fields.All(name) {
		out = append(out, address.Parse(f.Value)...)
	}
	return out
}

// Date returns the unfolded raw value of the first Date header, whether the
// header exists, and the parsed date when it is valid.
func (m *Message) Date() (raw string, present bool, d date.Date, valid bool) {
	f, ok := m.Root.Fields.Get("date")
	if !ok {
		return "", false, date.Date{}, false
	}
	d, valid = date.Parse(f.Value)
	return f.Value, true, d, valid
}

// normalize converts every CRLF to LF and changes nothing else.
func normalize(b []byte) []byte {
	if bytes.IndexByte(b, '\r') < 0 {
		return b
	}
	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); i++ {
		if b[i] == '\r' && i+1 < len(b) && b[i+1] == '\n' {
			continue
		}
		out = append(out, b[i])
	}
	return out
}

// Parse parses a raw message.
func Parse(raw []byte) *Message {
	m := &Message{Size: len(raw)}
	m.Root = m.parsePart(normalize(raw), nil, 0)
	m.selectBodies()
	return m
}

const tokenSpecials = " \t()<>@,;:\\\"/[]?="

func isToken(s string) bool {
	return s != "" && !strings.ContainsAny(s, tokenSpecials)
}

// contentType splits a usable "type/subtype" value proper.
func contentType(value string) (typ, sub string, ok bool) {
	i := strings.IndexByte(value, '/')
	if i < 0 {
		return "", "", false
	}
	typ, sub = value[:i], value[i+1:]
	if !isToken(typ) || !isToken(sub) {
		return "", "", false
	}
	return typ, sub, true
}

func (m *Message) parsePart(data []byte, parent *Part, depth int) *Part {
	p := &Part{Index: len(m.Parts), Depth: depth, Epilogue: -1}
	m.Parts = append(m.Parts, p)

	fields, bodyStart := header.Parse(data)
	body := data[bodyStart:]
	p.Fields = fields

	// Content-Type.
	var ct header.Structured
	ctPresent := false
	if f, ok := fields.Get("content-type"); ok {
		ct = header.ParseStructured(f.Value)
		ctPresent = true
	}
	typ, sub, ok := "", "", false
	if ctPresent {
		typ, sub, ok = contentType(ct.Token())
	}
	if !ok {
		typ, sub = "text", "plain"
		if parent != nil && parent.Type == "multipart" && parent.Subtype == "digest" {
			typ, sub = "message", "rfc822"
		}
	}
	p.Type, p.Subtype = typ, sub
	if typ == "text" {
		cs := "us-ascii"
		if v, ok := ct.Param("charset"); ok {
			cs = v
		}
		p.Charset = charset.Normalize(cs)
	}

	// Content-Disposition.
	var cd header.Structured
	if f, ok := fields.Get("content-disposition"); ok {
		cd = header.ParseStructured(f.Value)
		p.HasDisposition = true
		p.Disposition = cd.Token()
		if p.Disposition == "" {
			p.Disposition = "inline"
		}
	}

	// Content-Transfer-Encoding.
	p.Encoding = "7bit"
	if f, ok := fields.Get("content-transfer-encoding"); ok {
		p.Encoding = header.ParseStructured(f.Value).Token()
	}

	// Filename.
	if v, ok := cd.Param("filename"); ok {
		p.Filename, p.HasFilename = v, true
	} else if v, ok := ct.Param("name"); ok {
		p.Filename, p.HasFilename = v, true
	}

	switch {
	case p.Type == "multipart" && ct.Params["boundary"] != "":
		p.Kind = Multipart
		p.Boundary = ct.Params["boundary"]
		m.parseMultipart(p, body)
	case p.Type == "message" && p.Subtype == "rfc822":
		p.Kind = MessageContainer
		inner := transfer.Decode(body, p.Encoding)
		p.Children = []*Part{m.parsePart(inner, p, depth+1)}
	default:
		p.Kind = Leaf
		p.Content = transfer.Decode(body, p.Encoding)
	}
	return p
}

// delimiter classifies a line against the boundary: 0 not a delimiter, 1 a
// delimiter, 2 a close delimiter.
func delimiter(line, bb []byte) int {
	if len(line) < 2+len(bb) || line[0] != '-' || line[1] != '-' || !bytes.Equal(line[2:2+len(bb)], bb) {
		return 0
	}
	rest := line[2+len(bb):]
	kind := 1
	if len(rest) >= 2 && rest[0] == '-' && rest[1] == '-' {
		kind = 2
		rest = rest[2:]
	}
	for _, c := range rest {
		if c != ' ' && c != '\t' {
			return 0
		}
	}
	return kind
}

func trimLF(b []byte) []byte {
	if n := len(b); n > 0 && b[n-1] == '\n' {
		return b[:n-1]
	}
	return b
}

func (m *Message) parseMultipart(p *Part, body []byte) {
	bb := []byte(p.Boundary)
	type delim struct{ lineStart, next, kind int }
	var first *delim
	childStart := -1
	var kids [][]byte
	pos := 0
	closed := false
	for pos < len(body) {
		end := bytes.IndexByte(body[pos:], '\n')
		lineEnd, next := len(body), len(body)
		if end >= 0 {
			lineEnd = pos + end
			next = lineEnd + 1
		}
		k := 0
		// Cheap pre-check before the full comparison.
		if lineEnd-pos >= 2 && body[pos] == '-' && body[pos+1] == '-' {
			k = delimiter(body[pos:lineEnd], bb)
		}
		if k != 0 {
			if first == nil {
				first = &delim{pos, next, k}
				p.Preamble = len(trimLF(body[:pos]))
			}
			if childStart >= 0 {
				kids = append(kids, trimLF(body[childStart:pos]))
			}
			if k == 2 {
				p.Epilogue = len(body) - next
				closed = true
				break
			}
			childStart = next
		}
		pos = next
	}
	if first == nil {
		p.Preamble = len(body)
		return
	}
	if !closed && childStart >= 0 {
		kids = append(kids, trimLF(body[childStart:]))
	}
	for _, kb := range kids {
		p.Children = append(p.Children, m.parsePart(kb, p, p.Depth+1))
	}
}

// selectBodies chooses the text and HTML bodies and the attachments.
func (m *Message) selectBodies() {
	var walk func(p *Part)
	walk = func(p *Part) {
		if p.Kind == Leaf && (!p.HasDisposition || p.Disposition != "attachment") {
			if p.Type == "text" && p.Subtype == "plain" && m.TextBody == nil {
				m.TextBody = p
			}
			if p.Type == "text" && p.Subtype == "html" && m.HTMLBody == nil {
				m.HTMLBody = p
			}
		}
		if p.Kind == Multipart {
			for _, c := range p.Children {
				walk(c)
			}
		}
	}
	walk(m.Root)
	for _, p := range m.Parts {
		if p.Kind != Leaf {
			continue
		}
		switch p {
		case m.TextBody:
			p.Role = RoleText
		case m.HTMLBody:
			p.Role = RoleHTML
		default:
			p.Role = RoleAttachment
			m.Attachments = append(m.Attachments, p)
		}
	}
}
