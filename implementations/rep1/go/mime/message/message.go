// Package message builds the MIME part tree of one email message and selects
// its text and html bodies and its attachments.
package message

import (
	"bytes"
	"strings"

	"mimedump/charset"
	"mimedump/checksum"
	"mimedump/header"
	"mimedump/internal/scan"
	"mimedump/lines"
	"mimedump/params"
	"mimedump/transfer"
)

// Kind classifies a part.
type Kind int

// Part kinds.
const (
	Leaf       Kind = iota // content is the decoded body
	Multipart              // multipart/* with a usable boundary
	MessageEnv             // message/rfc822: exactly one child
)

// Role says what a leaf is used for.
type Role int

// Leaf roles.
const (
	NoRole Role = iota // containers
	RoleText
	RoleHTML
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
	Index    int
	Depth    int
	Kind     Kind
	Headers  []header.Field
	Type     string // lower-case "type/subtype"
	Subtype  string
	Charset  string // normalised charset name; only meaningful for text/*
	Encoding string // Content-Transfer-Encoding token
	Children []*Part

	HasDisposition bool
	Disposition    string
	Filename       string
	HasFilename    bool

	// Multipart containers.
	Boundary string
	Preamble int // length in bytes
	Epilogue int // length in bytes, or -1 when absent

	// Leaves.
	Content []byte
	Adler32 uint32
	Text    string // decoded text of a text/* leaf
	Chars   int    // number of code points in Text
	Role    Role
}

// IsText reports whether the part has a text/* type.
func (p *Part) IsText() bool { return p.Type == "text" }

// Message is a parsed email.
type Message struct {
	Parts       []*Part // all parts in pre-order; Parts[0] is the root
	Text, HTML  *Part   // selected bodies, or nil
	Attachments []*Part // in part-index order
}

// Parse parses one raw message (any mix of LF and CRLF line endings).
func Parse(raw []byte) *Message {
	m := &Message{}
	m.parsePart(lines.NormalizeCRLF(raw), nil, 0)
	m.selectBodies()
	return m
}

func (m *Message) parsePart(data []byte, parent *Part, depth int) *Part {
	fields, bodyStart := header.Parse(data)
	body := data[bodyStart:]
	p := &Part{Index: len(m.Parts), Depth: depth, Headers: fields, Epilogue: -1}
	m.Parts = append(m.Parts, p)

	var ct params.Value
	ctField, hasCT := header.Find(fields, "content-type")
	if hasCT {
		ct = params.Parse(ctField.Raw)
	}
	p.Type, p.Subtype = splitType(scan.LowerASCII(ct.Main))
	if p.Type == "" {
		p.Type, p.Subtype = "text", "plain"
		if parent != nil && parent.Type == "multipart" && parent.Subtype == "digest" {
			p.Type, p.Subtype = "message", "rfc822"
		}
	}
	p.Encoding = "7bit"
	if f, ok := header.Find(fields, "content-transfer-encoding"); ok {
		p.Encoding = scan.LowerASCII(params.Parse(f.Raw).Main)
	}
	if p.Type == "text" {
		p.Charset = "us-ascii"
		if cs, ok := ct.Get("charset"); ok {
			p.Charset = charset.Normalize(cs)
		}
	}
	if f, ok := header.Find(fields, "content-disposition"); ok {
		cd := params.Parse(f.Raw)
		p.HasDisposition = true
		p.Disposition = scan.LowerASCII(cd.Main)
		if p.Disposition == "" {
			p.Disposition = "inline"
		}
		p.Filename, p.HasFilename = cd.Get("filename")
	}
	if !p.HasFilename {
		p.Filename, p.HasFilename = ct.Get("name")
	}

	switch boundary, _ := ct.Get("boundary"); {
	case p.Type == "multipart" && boundary != "":
		p.Kind = Multipart
		p.Boundary = boundary
		m.splitMultipart(p, body, boundary)
	case p.Type+"/"+p.Subtype == "message/rfc822":
		p.Kind = MessageEnv
		m.parsePart(transfer.Decode(body, p.Encoding), p, depth+1)
		p.Children = append(p.Children, m.Parts[p.Index+1])
	default:
		p.Kind = Leaf
		p.Content = transfer.Decode(body, p.Encoding)
		p.Adler32 = checksum.Adler32(p.Content)
		if p.Type == "text" {
			p.Text = charset.Decode(p.Content, p.Charset)
			p.Chars = charset.RuneCount(p.Text)
		}
	}
	return p
}

// splitType splits a Content-Type main value into type and subtype, or
// returns empty strings if it is not "token/token".
func splitType(v string) (string, string) {
	const bad = " \t()<>@,;:\\\"/[]?="
	slash := -1
	for i := 0; i < len(v); i++ {
		if v[i] == '/' {
			if slash >= 0 {
				return "", ""
			}
			slash = i
		} else if strings.IndexByte(bad, v[i]) >= 0 {
			return "", ""
		}
	}
	if slash <= 0 || slash == len(v)-1 {
		return "", ""
	}
	return v[:slash], v[slash+1:]
}

// delimiter classifies a line against the boundary prefix "--"+boundary.
func delimiter(line []byte, prefix []byte) (isDelim, isClose bool) {
	if !bytes.HasPrefix(line, prefix) {
		return false, false
	}
	rest := line[len(prefix):]
	if bytes.HasPrefix(rest, []byte("--")) {
		isClose = true
		rest = rest[2:]
	}
	for _, c := range rest {
		if c != ' ' && c != '\t' {
			return false, false
		}
	}
	return true, isClose
}

func trimLF(b []byte) []byte {
	if n := len(b); n > 0 && b[n-1] == '\n' {
		return b[:n-1]
	}
	return b
}

func (m *Message) splitMultipart(p *Part, body []byte, boundary string) {
	prefix := []byte("--" + boundary)
	type span struct{ start, end int } // child body bounds
	var children []span
	first := true
	childStart := -1
	p.Preamble = len(body)
	for pos := 0; pos < len(body); {
		line, size, _ := lines.Next(body[pos:])
		isD, isClose := false, false
		if len(line) >= len(prefix) { // cheap reject
			isD, isClose = delimiter(line, prefix)
		}
		if !isD {
			pos += size
			continue
		}
		if childStart >= 0 {
			children = append(children, span{childStart, len(trimLF(body[childStart:pos])) + childStart})
		}
		if first {
			p.Preamble = len(trimLF(body[:pos]))
			first = false
		}
		if isClose {
			p.Epilogue = len(body) - (pos + size)
			childStart = -1
			break
		}
		childStart = pos + size
		pos += size
	}
	if childStart >= 0 { // no close delimiter: last child runs to the end
		children = append(children, span{childStart, len(trimLF(body[childStart:])) + childStart})
	}
	for _, c := range children {
		p.Children = append(p.Children, m.parsePart(body[c.start:c.end], p, p.Depth+1))
	}
}

// selectBodies picks the text and html bodies and assigns leaf roles.
func (m *Message) selectBodies() {
	var walk func(p *Part)
	walk = func(p *Part) {
		if p.Kind == Leaf && (!p.HasDisposition || p.Disposition != "attachment") {
			if p.Type+"/"+p.Subtype == "text/plain" && m.Text == nil {
				m.Text = p
			} else if p.Type+"/"+p.Subtype == "text/html" && m.HTML == nil {
				m.HTML = p
			}
		}
		if p.Kind == MessageEnv {
			return
		}
		for _, c := range p.Children {
			walk(c)
		}
	}
	walk(m.Parts[0])
	for _, p := range m.Parts {
		if p.Kind != Leaf {
			continue
		}
		switch p {
		case m.Text:
			p.Role = RoleText
		case m.HTML:
			p.Role = RoleHTML
		default:
			p.Role = RoleAttachment
			m.Attachments = append(m.Attachments, p)
		}
	}
}
