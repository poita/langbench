// Package cli implements the line-oriented command language of the webhooks
// tool: it parses commands from an input buffer and renders the results.
//
// Run is a pure function from the whole input to the whole output, so the
// command-line tool is a thin wrapper that reads stdin and writes stdout.
package cli

import (
	"bytes"

	"webhooks/base64"
	"webhooks/hexcodec"
	"webhooks/hmac"
	"webhooks/sha256"
	"webhooks/signature"
	"webhooks/sim"
)

// Run executes every command in input and returns the output. It never fails:
// malformed lines produce the single word "error".
func Run(input []byte) []byte {
	r := runner{input: input, out: make([]byte, 0, 4096)}
	for {
		line, ok := r.nextLine()
		if !ok {
			return r.out
		}
		if blank(line) {
			continue
		}
		fields, ok := r.split(line)
		if !ok {
			r.fail()
			continue
		}
		if !r.command(fields) {
			r.fail()
		}
	}
}

type runner struct {
	input  []byte
	pos    int
	out    []byte
	fields [][]byte
}

func (r *runner) fail() { r.out = append(r.out, "error\n"...) }

// nextLine returns the next line without its terminator.
func (r *runner) nextLine() ([]byte, bool) {
	if r.pos >= len(r.input) {
		return nil, false
	}
	rest := r.input[r.pos:]
	if i := bytes.IndexByte(rest, '\n'); i >= 0 {
		r.pos += i + 1
		return rest[:i], true
	}
	r.pos = len(r.input)
	return rest, true
}

func blank(line []byte) bool {
	for _, c := range line {
		if c != ' ' {
			return false
		}
	}
	return true
}

// split splits a line on single spaces into the runner's reusable field
// slice; it reports false if any field is empty.
func (r *runner) split(line []byte) ([][]byte, bool) {
	f := r.fields[:0]
	for {
		i := bytes.IndexByte(line, ' ')
		if i < 0 {
			f = append(f, line)
			break
		}
		f = append(f, line[:i])
		line = line[i+1:]
	}
	r.fields = f
	for _, x := range f {
		if len(x) == 0 {
			return f, false
		}
	}
	return f, true
}

// command executes one parsed command; it reports false for an error result.
func (r *runner) command(f [][]byte) bool {
	switch string(f[0]) {
	case "sha256":
		if len(f) != 2 {
			return false
		}
		msg, err := hexcodec.DecodeArg(f[1])
		if err != nil {
			return false
		}
		sum := sha256.Sum256(msg)
		r.line(hexcodec.Append(r.out, sum[:]))
	case "hmac":
		if len(f) != 3 {
			return false
		}
		key, err1 := hexcodec.DecodeArg(f[1])
		msg, err2 := hexcodec.DecodeArg(f[2])
		if err1 != nil || err2 != nil {
			return false
		}
		sum := hmac.Sum256(key, msg)
		r.line(hexcodec.Append(r.out, sum[:]))
	case "b64enc", "b64urlenc":
		if len(f) != 2 {
			return false
		}
		data, err := hexcodec.DecodeArg(f[1])
		if err != nil {
			return false
		}
		if len(data) == 0 {
			r.line(append(r.out, '-'))
		} else if f[0][3] == 'e' {
			r.line(base64.AppendStd(r.out, data))
		} else {
			r.line(base64.AppendURL(r.out, data))
		}
	case "b64dec":
		if len(f) != 2 {
			return false
		}
		text, err := hexcodec.DecodeArg(f[1])
		if err != nil {
			return false
		}
		raw, err := base64.Decode(nil, text)
		if err != nil {
			return false
		}
		r.line(hexcodec.AppendArg(r.out, raw))
	case "secret":
		if len(f) != 2 {
			return false
		}
		s, err := signature.ParseSecret(f[1])
		if err != nil {
			return false
		}
		r.line(hexcodec.Append(r.out, s.Raw))
	case "sign":
		return len(f) == 5 && r.sign(f)
	case "verify":
		return len(f) == 7 && r.verify(f)
	case "simulate":
		if len(f) != 1 {
			return false
		}
		return r.simulate()
	default:
		return false
	}
	return true
}

// line terminates the output line whose bytes have just been appended.
func (r *runner) line(out []byte) { r.out = append(out, '\n') }

func (r *runner) sign(f [][]byte) bool {
	secrets, err := signature.ParseSecrets(f[1])
	if err != nil || !signature.ValidID(f[2]) {
		return false
	}
	if _, ok := signature.ParseTimestamp(f[3]); !ok {
		return false
	}
	payload, err := hexcodec.DecodeArg(f[4])
	if err != nil {
		return false
	}
	r.line(signature.AppendHeader(r.out, secrets, f[2], f[3], payload))
	return true
}

func (r *runner) verify(f [][]byte) bool {
	secrets, err := signature.ParseSecrets(f[1])
	if err != nil || !signature.ValidID(f[2]) || !signature.ValidTimestampText(f[3]) {
		return false
	}
	now, ok := signature.ParseTimestamp(f[4])
	if !ok {
		return false
	}
	header, err1 := hexcodec.DecodeArg(f[5])
	payload, err2 := hexcodec.DecodeArg(f[6])
	if err1 != nil || err2 != nil {
		return false
	}
	res := signature.Verify(secrets, f[2], f[3], now, header, payload)
	if res.OK {
		out := append(r.out, "ok "...)
		out = appendInt(out, res.Secret)
		out = append(out, ' ')
		r.line(appendInt(out, res.Token))
	} else {
		r.line(append(append(r.out, "fail "...), res.Reason...))
	}
	return true
}

func appendInt(dst []byte, v int) []byte {
	if v == 0 {
		return append(dst, '0')
	}
	var tmp [20]byte
	i := len(tmp)
	for ; v > 0; v /= 10 {
		i--
		tmp[i] = byte('0' + v%10)
	}
	return append(dst, tmp[i:]...)
}

// simulate consumes a block of lines after a "simulate" line, through the
// terminating "end". An invalid block yields false (after consuming it all).
func (r *runner) simulate() bool {
	var b sim.Builder
	bad := false
	for {
		line, ok := r.nextLine()
		if !ok {
			return false // end of input before "end"
		}
		if string(line) == "end" {
			break
		}
		if bad || blank(line) {
			continue
		}
		f, ok := r.split(line)
		if !ok {
			bad = true
			continue
		}
		switch string(f[0]) {
		case "endpoint":
			bad = b.AddEndpoint(f[1:]) != nil
		case "event":
			bad = b.AddEvent(f[1:]) != nil
		default:
			bad = true
		}
	}
	if bad {
		return false
	}
	cfg, err := b.Config()
	if err != nil {
		return false
	}
	r.out = sim.Run(cfg).AppendTo(r.out)
	return true
}
