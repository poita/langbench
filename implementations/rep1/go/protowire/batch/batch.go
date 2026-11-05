// Package batch implements the line-oriented request protocol: a schema, a
// line consisting of "--", and then one decode or encode request per line.
//
// Each request produces exactly one output line: the result, or the word
// "error" when the request is malformed.
package batch

import (
	"bytes"

	"protowire/codec"
	"protowire/schema"
	"protowire/wire"
)

// ErrorLine is the output line for a malformed request.
const ErrorLine = "error"

var separator = []byte("--")

// Split divides input into the schema text (everything before the first line
// that is exactly "--") and the request text that follows that line. If there
// is no separator line, the whole input is schema and there are no requests.
func Split(input []byte) (schemaText, requests []byte) {
	pos := 0
	for pos <= len(input) {
		end := bytes.IndexByte(input[pos:], '\n')
		lineEnd := len(input)
		next := len(input)
		if end >= 0 {
			lineEnd = pos + end
			next = lineEnd + 1
		}
		if bytes.Equal(input[pos:lineEnd], separator) {
			return input[:pos], input[next:]
		}
		if end < 0 {
			break
		}
		pos = next
	}
	return input, nil
}

// Run parses the schema in input and answers every request, returning the
// complete output. If the schema cannot be parsed, Run returns the error and
// no output.
func Run(input []byte) ([]byte, error) {
	schemaText, requests := Split(input)
	sch, err := schema.Parse(schemaText)
	if err != nil {
		return nil, err
	}
	return Answer(sch, requests), nil
}

// Answer handles every request line in requests against sch and returns the
// output, one line per request. A final line without a trailing newline is
// still a request; the newline after the last request does not start another.
func Answer(sch *schema.Schema, requests []byte) []byte {
	h := handler{c: codec.New(sch), s: sch}
	out := make([]byte, 0, len(requests)+len(requests)/2+64)
	for len(requests) > 0 {
		var line []byte
		if i := bytes.IndexByte(requests, '\n'); i >= 0 {
			line, requests = requests[:i], requests[i+1:]
		} else {
			line, requests = requests, nil
		}
		mark := len(out)
		var ok bool
		if out, ok = h.handle(out, line); !ok {
			out = append(out[:mark], ErrorLine...)
		}
		out = append(out, '\n')
	}
	return out
}

type handler struct {
	c       *codec.Codec
	s       *schema.Schema
	scratch []byte // decoded hex / encoded bytes, reused across requests
}

// handle appends the result of one request line to out. It reports false if
// the request is malformed (out may then hold partial output).
func (h *handler) handle(out, line []byte) ([]byte, bool) {
	cmd, rest, _ := bytes.Cut(line, []byte{' '})
	var decode bool
	switch string(cmd) {
	case "decode":
		decode = true
	case "encode":
	default:
		return out, false
	}
	nameBytes, arg, hasArg := bytes.Cut(rest, []byte{' '})
	m := h.s.LookupBytes(nameBytes)
	if m == nil {
		return out, false
	}
	if decode {
		data := h.scratch[:0]
		if hasArg {
			var ok bool
			if len(arg) == 0 {
				return out, false // "decode Name " with nothing after the space
			}
			if data, ok = wire.AppendUnhex(data, arg); !ok {
				return out, false
			}
		}
		h.scratch = data
		res, err := h.c.AppendDecode(out, m, data)
		return res, err == nil
	}
	if !hasArg {
		return out, false
	}
	enc, err := h.c.AppendEncode(h.scratch[:0], m, arg)
	h.scratch = enc
	if err != nil {
		return out, false
	}
	return wire.AppendHex(out, enc), true
}
