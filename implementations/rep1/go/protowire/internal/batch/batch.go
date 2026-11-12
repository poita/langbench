// Package batch implements the protowire command-line I/O contract: a schema,
// a "--" separator line, then one decode/encode request per line, answered
// with one output line each.
package batch

import (
	"bytes"
	"io"

	"example.com/protowire"
)

const errorLine = "error"

// Run processes a complete input and writes one output line per request.
// Malformed requests produce the line "error"; Run itself only fails on write
// errors.
func Run(in []byte, w io.Writer) error {
	schemaSrc, requests := split(in)
	schema, schemaErr := protowire.ParseSchema(string(schemaSrc))

	var out []byte
	for len(requests) > 0 {
		var line []byte
		if i := bytes.IndexByte(requests, '\n'); i >= 0 {
			line, requests = requests[:i], requests[i+1:]
		} else {
			line, requests = requests, nil
		}
		if schemaErr != nil {
			out = append(out, errorLine...)
		} else {
			out = HandleRequest(schema, line, out)
		}
		out = append(out, '\n')
		if len(out) > 1<<20 {
			if _, err := w.Write(out); err != nil {
				return err
			}
			out = out[:0]
		}
	}
	_, err := w.Write(out)
	return err
}

// split separates the schema from the requests at the first line that is
// exactly "--". Without a separator there are no requests.
func split(in []byte) (schema, requests []byte) {
	pos := 0
	for pos <= len(in) {
		end := bytes.IndexByte(in[pos:], '\n')
		var line []byte
		next := len(in) + 1
		if end < 0 {
			line = in[pos:]
		} else {
			line = in[pos : pos+end]
			next = pos + end + 1
		}
		if string(line) == "--" {
			if next > len(in) {
				return in[:pos], nil
			}
			return in[:pos], in[next:]
		}
		pos = next
	}
	return in, nil
}

// HandleRequest executes one request line against schema and appends the
// result line (without newline) to dst: the text form for decode, lowercase
// hex for encode, or "error".
func HandleRequest(schema *protowire.Schema, line []byte, dst []byte) []byte {
	if res, ok := handle(schema, line); ok {
		return append(dst, res...)
	}
	return append(dst, errorLine...)
}

func handle(schema *protowire.Schema, line []byte) ([]byte, bool) {
	var decode bool
	switch {
	case bytes.HasPrefix(line, []byte("decode ")):
		decode = true
	case bytes.HasPrefix(line, []byte("encode ")):
	default:
		return nil, false
	}
	rest := line[len("decode "):]
	name, arg := rest, []byte(nil)
	hasArg := false
	if i := bytes.IndexByte(rest, ' '); i >= 0 {
		name, arg, hasArg = rest[:i], rest[i+1:], true
	}
	desc := schema.Message(string(name))
	if desc == nil {
		return nil, false
	}

	if decode {
		var data []byte
		if hasArg {
			if len(arg) == 0 {
				return nil, false
			}
			var ok bool
			if data, ok = decodeHex(arg); !ok {
				return nil, false
			}
		}
		m, err := desc.Unmarshal(data)
		if err != nil {
			return nil, false
		}
		return m.AppendText(nil), true
	}

	if !hasArg {
		return nil, false
	}
	m, err := desc.ParseText(arg)
	if err != nil {
		return nil, false
	}
	return encodeHex(m.Marshal()), true
}

const hexDigits = "0123456789abcdef"

func encodeHex(b []byte) []byte {
	out := make([]byte, 2*len(b))
	for i, c := range b {
		out[2*i], out[2*i+1] = hexDigits[c>>4], hexDigits[c&15]
	}
	return out
}

// decodeHex decodes strictly lowercase, even-length hex.
func decodeHex(h []byte) ([]byte, bool) {
	if len(h)%2 != 0 {
		return nil, false
	}
	val := func(c byte) int {
		switch {
		case c >= '0' && c <= '9':
			return int(c - '0')
		case c >= 'a' && c <= 'f':
			return int(c-'a') + 10
		}
		return -1
	}
	out := make([]byte, len(h)/2)
	for i := range out {
		hi, lo := val(h[2*i]), val(h[2*i+1])
		if hi < 0 || lo < 0 {
			return nil, false
		}
		out[i] = byte(hi<<4 | lo)
	}
	return out, true
}
