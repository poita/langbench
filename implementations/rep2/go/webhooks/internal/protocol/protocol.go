// Package protocol implements the line-oriented command stream of the
// webhooks command-line tool on top of the library packages: it parses
// commands, runs them and renders the results.
package protocol

import (
	"bytes"

	"example.com/webhooks/base64"
	"example.com/webhooks/hmac"
	"example.com/webhooks/sha256"
	"example.com/webhooks/signature"
)

var errorLine = []byte("error\n")

// Run interprets the whole command stream in and returns everything the tool
// prints. It never fails: malformed lines produce the line "error".
func Run(in []byte) []byte {
	r := &reader{buf: in}
	out := make([]byte, 0, len(in)/2+256)
	var fields [][]byte
	for {
		line, ok := r.next()
		if !ok {
			return out
		}
		if isBlank(line) {
			continue
		}
		var fieldsOK bool
		fields, fieldsOK = splitFields(line, fields)
		if !fieldsOK {
			out = append(out, errorLine...)
			continue
		}
		if string(fields[0]) == "simulate" && len(fields) == 1 {
			out = r.simulate(out)
			continue
		}
		out = command(out, fields)
	}
}

// reader walks the input buffer line by line, returning views into it.
type reader struct {
	buf []byte
	pos int
}

func (r *reader) next() ([]byte, bool) {
	if r.pos >= len(r.buf) {
		return nil, false
	}
	rest := r.buf[r.pos:]
	i := bytes.IndexByte(rest, '\n')
	if i < 0 {
		r.pos = len(r.buf)
		return rest, true
	}
	r.pos += i + 1
	return rest[:i], true
}

// command executes one non-simulate command, appending its output (or
// "error") to out.
func command(out []byte, f [][]byte) []byte {
	res, ok := execute(out, f)
	if !ok {
		return append(out, errorLine...)
	}
	return append(res, '\n')
}

// execute appends a command's output without the trailing newline. It
// reports ok=false (leaving out's contents unspecified past its original
// length) when the line is an error.
func execute(out []byte, f [][]byte) ([]byte, bool) {
	name := string(f[0])
	switch name {
	case "sha256":
		if len(f) != 2 {
			return out, false
		}
		data, ok := decodeHex(f[1])
		if !ok {
			return out, false
		}
		sum := sha256.Sum256(data)
		return appendHex(out, sum[:]), true
	case "hmac":
		if len(f) != 3 {
			return out, false
		}
		key, ok1 := decodeHex(f[1])
		msg, ok2 := decodeHex(f[2])
		if !ok1 || !ok2 {
			return out, false
		}
		sum := hmac.Sum256(key, msg)
		return appendHex(out, sum[:]), true
	case "b64enc", "b64urlenc":
		if len(f) != 2 {
			return out, false
		}
		data, ok := decodeHex(f[1])
		if !ok {
			return out, false
		}
		if len(data) == 0 {
			return append(out, '-'), true
		}
		if name == "b64enc" {
			return base64.AppendStandard(out, data), true
		}
		return base64.AppendURL(out, data), true
	case "b64dec":
		if len(f) != 2 {
			return out, false
		}
		text, ok := decodeHex(f[1])
		if !ok {
			return out, false
		}
		dec, err := base64.Decode(text)
		if err != nil {
			return out, false
		}
		return appendHex(out, dec), true
	case "secret":
		if len(f) != 2 || !isPrintable(f[1]) {
			return out, false
		}
		return execSecret(out, f[1])
	case "sign":
		if len(f) != 5 {
			return out, false
		}
		keys, ok := parseSecrets(f[1])
		if !ok {
			return out, false
		}
		id, ok := parseID(f[2])
		if !ok {
			return out, false
		}
		if _, ok := signature.ParseTimestamp(f[3]); !ok {
			return out, false
		}
		payload, ok := decodeHex(f[4])
		if !ok {
			return out, false
		}
		return signature.AppendSignature(out, keys, id, string(f[3]), payload), true
	case "verify":
		if len(f) != 7 {
			return out, false
		}
		return execVerify(out, f)
	}
	return out, false
}

func execSecret(out []byte, f []byte) ([]byte, bool) {
	if len(f) > 512 || bytes.IndexByte(f, ',') >= 0 {
		return out, false
	}
	raw, err := signature.DecodeSecret(string(f))
	if err != nil {
		return out, false
	}
	return appendHex(out, raw), true
}

func execVerify(out []byte, f [][]byte) ([]byte, bool) {
	keys, ok := parseSecrets(f[1])
	if !ok {
		return out, false
	}
	id, ok := parseID(f[2])
	if !ok {
		return out, false
	}
	if len(f[3]) > 64 || !isPrintable(f[3]) {
		return out, false
	}
	now, ok := signature.ParseTimestamp(f[4])
	if !ok {
		return out, false
	}
	header, ok := decodeHex(f[5])
	if !ok {
		return out, false
	}
	payload, ok := decodeHex(f[6])
	if !ok {
		return out, false
	}
	m, err := signature.Verify(keys, id, string(f[3]), header, payload, now)
	if err != nil {
		out = append(out, "fail "...)
		return append(out, err.Error()...), true
	}
	out = append(out, "ok "...)
	out = appendInt(out, m.Secret)
	out = append(out, ' ')
	return appendInt(out, m.Token), true
}
