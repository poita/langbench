// Package commands interprets the line-oriented command protocol: it reads a
// stream of commands (sha256, hmac, b64enc, sign, verify, simulate, ...) and
// produces one result per command. It is the glue between the text protocol
// and the library packages; all malformed input yields the single word
// "error" and never aborts the run.
package commands

import (
	"bytes"
	"io"
	"strconv"

	"example.com/webhooks/b64"
	"example.com/webhooks/hexfield"
	"example.com/webhooks/hmac"
	"example.com/webhooks/sha256"
	"example.com/webhooks/signature"
)

// Run reads all of r, executes every command and writes the output to w in a
// single write.
func Run(r io.Reader, w io.Writer) error {
	in, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	_, err = w.Write(Execute(in, nil))
	return err
}

// Execute runs the commands in input and appends the output to out, returning
// the extended slice.
func Execute(input, out []byte) []byte {
	e := &executor{input: input, out: out}
	for {
		line, ok := e.nextLine()
		if !ok {
			return e.out
		}
		if isBlank(line) {
			continue
		}
		e.fields = splitFields(e.fields, line)
		e.dispatch()
	}
}

type executor struct {
	input  []byte
	out    []byte
	fields [][]byte
}

// nextLine returns the next line without its terminator.
func (e *executor) nextLine() ([]byte, bool) {
	if len(e.input) == 0 {
		return nil, false
	}
	line := e.input
	if i := bytes.IndexByte(e.input, '\n'); i >= 0 {
		line, e.input = e.input[:i], e.input[i+1:]
	} else {
		e.input = nil
	}
	return line, true
}

func (e *executor) fail() { e.out = append(e.out, "error\n"...) }

func (e *executor) emitHex(b []byte) {
	e.out = hexfield.AppendEncode(e.out, b)
	e.out = append(e.out, '\n')
}

func (e *executor) dispatch() {
	f := e.fields
	if hasEmpty(f) {
		e.fail()
		return
	}
	switch string(f[0]) {
	case "sha256":
		e.cmdSHA256()
	case "hmac":
		e.cmdHMAC()
	case "b64enc":
		e.cmdB64(false)
	case "b64urlenc":
		e.cmdB64(true)
	case "b64dec":
		e.cmdB64Dec()
	case "secret":
		e.cmdSecret()
	case "sign":
		e.cmdSign()
	case "verify":
		e.cmdVerify()
	case "simulate":
		e.cmdSimulate()
	default:
		e.fail()
	}
}

func (e *executor) cmdSHA256() {
	if len(e.fields) != 2 {
		e.fail()
		return
	}
	data, err := hexfield.Decode(e.fields[1])
	if err != nil {
		e.fail()
		return
	}
	sum := sha256.Sum256(data)
	e.emitHex(sum[:])
}

func (e *executor) cmdHMAC() {
	if len(e.fields) != 3 {
		e.fail()
		return
	}
	key, err1 := hexfield.Decode(e.fields[1])
	msg, err2 := hexfield.Decode(e.fields[2])
	if err1 != nil || err2 != nil {
		e.fail()
		return
	}
	sum := hmac.Sum256(key, msg)
	e.emitHex(sum[:])
}

func (e *executor) cmdB64(url bool) {
	if len(e.fields) != 2 {
		e.fail()
		return
	}
	data, err := hexfield.Decode(e.fields[1])
	if err != nil {
		e.fail()
		return
	}
	if len(data) == 0 {
		e.out = append(e.out, "-\n"...)
		return
	}
	if url {
		e.out = b64.AppendEncodeURL(e.out, data)
	} else {
		e.out = b64.AppendEncode(e.out, data)
	}
	e.out = append(e.out, '\n')
}

func (e *executor) cmdB64Dec() {
	if len(e.fields) != 2 {
		e.fail()
		return
	}
	text, err := hexfield.Decode(e.fields[1])
	if err != nil {
		e.fail()
		return
	}
	raw, err := b64.Decode(string(text))
	if err != nil {
		e.fail()
		return
	}
	e.emitHex(raw)
}

func (e *executor) cmdSecret() {
	if len(e.fields) != 2 || !isToken(e.fields[1], maxSecretLen) || bytes.IndexByte(e.fields[1], ',') >= 0 {
		e.fail()
		return
	}
	s, err := signature.ParseSecret(string(e.fields[1]))
	if err != nil {
		e.fail()
		return
	}
	e.emitHex(s.Key())
}

func (e *executor) cmdSign() {
	f := e.fields
	if len(f) != 5 {
		e.fail()
		return
	}
	secrets, ok := parseSecrets(f[1])
	if !ok || !isToken(f[2], maxIDLen) {
		e.fail()
		return
	}
	if _, ok := parseInt(f[3]); !ok {
		e.fail()
		return
	}
	body, err := hexfield.Decode(f[4])
	if err != nil {
		e.fail()
		return
	}
	e.out = signature.AppendSign(e.out, secrets, string(f[2]), string(f[3]), body)
	e.out = append(e.out, '\n')
}

func (e *executor) cmdVerify() {
	f := e.fields
	if len(f) != 7 {
		e.fail()
		return
	}
	secrets, ok := parseSecrets(f[1])
	if !ok || !isToken(f[2], maxIDLen) || !isToken(f[3], maxVerifyTsLen) {
		e.fail()
		return
	}
	now, ok := parseInt(f[4])
	if !ok {
		e.fail()
		return
	}
	header, err1 := hexfield.Decode(f[5])
	body, err2 := hexfield.Decode(f[6])
	if err1 != nil || err2 != nil {
		e.fail()
		return
	}
	m, err := signature.Verify(secrets, string(f[2]), string(f[3]), string(header), body, now)
	if err != nil {
		e.out = append(e.out, "fail "...)
		e.out = append(e.out, err.Error()...)
	} else {
		e.out = append(e.out, "ok "...)
		e.out = strconv.AppendInt(e.out, int64(m.Secret), 10)
		e.out = append(e.out, ' ')
		e.out = strconv.AppendInt(e.out, int64(m.Token), 10)
	}
	e.out = append(e.out, '\n')
}
