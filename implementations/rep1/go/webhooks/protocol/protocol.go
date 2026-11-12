// Package protocol implements the line-oriented command language of the
// webhooks CLI on top of the library packages: primitives, secrets, signing,
// verification and the delivery simulator. See the README for the grammar.
//
// Malformed input never aborts the run: every bad command line yields the
// single word "error" as its output.
package protocol

import (
	"bufio"
	"io"
	"strings"

	"example.com/webhooks"
	"example.com/webhooks/b64"
	"example.com/webhooks/hmac"
	"example.com/webhooks/sha256"
)

const errorLine = "error"

// Run reads commands from in until EOF and writes one result (or, for a
// simulate block, several lines) per command to out. It returns the first I/O
// error encountered, if any; protocol errors are reported in the output.
func Run(in io.Reader, out io.Writer) error {
	r := bufio.NewReaderSize(in, 1<<16)
	w := bufio.NewWriterSize(out, 1<<16)
	lines := &lineReader{r: r}

	for {
		line, ok := lines.next()
		if !ok {
			break
		}
		if isBlank(line) {
			continue
		}
		fields := strings.Split(line, " ")
		if fields[0] == "simulate" && len(fields) == 1 {
			runSimulate(lines, w)
			continue
		}
		res, ok := execute(fields)
		if !ok {
			res = errorLine
		}
		w.WriteString(res)
		w.WriteByte('\n')
	}
	if err := w.Flush(); err != nil {
		return err
	}
	return lines.err
}

// lineReader yields LF-terminated lines of any length.
type lineReader struct {
	r   *bufio.Reader
	err error // first non-EOF read error
}

func (l *lineReader) next() (string, bool) {
	var sb []byte
	for {
		chunk, err := l.r.ReadSlice('\n')
		sb = append(sb, chunk...)
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			if err != io.EOF {
				l.err = err
			}
			if len(sb) == 0 {
				return "", false
			}
			return string(sb), true
		}
		return string(sb[:len(sb)-1]), true
	}
}

func isBlank(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != ' ' {
			return false
		}
	}
	return true
}

// execute runs one non-simulate command. ok is false for a malformed line.
func execute(f []string) (out string, ok bool) {
	for _, s := range f {
		if s == "" {
			return "", false
		}
	}
	argc := map[string]int{
		"sha256": 2, "hmac": 3, "b64enc": 2, "b64urlenc": 2, "b64dec": 2,
		"secret": 2, "sign": 5, "verify": 7,
	}
	if n, known := argc[f[0]]; !known || n != len(f) {
		return "", false
	}

	switch f[0] {
	case "sha256":
		b, err := parseHex(f[1])
		if err != nil {
			return "", false
		}
		sum := sha256.Sum256(b)
		return formatHex(sum[:]), true

	case "hmac":
		key, err1 := parseHex(f[1])
		msg, err2 := parseHex(f[2])
		if err1 != nil || err2 != nil {
			return "", false
		}
		sum := hmac.Sum(key, msg)
		return formatHex(sum[:]), true

	case "b64enc", "b64urlenc":
		b, err := parseHex(f[1])
		if err != nil {
			return "", false
		}
		if len(b) == 0 {
			return "-", true
		}
		if f[0] == "b64enc" {
			return b64.EncodeStd(b), true
		}
		return b64.EncodeURL(b), true

	case "b64dec":
		b, err := parseHex(f[1])
		if err != nil {
			return "", false
		}
		raw, err := b64.Decode(string(b))
		if err != nil {
			return "", false
		}
		return formatHex(raw), true

	case "secret":
		key, err := parseSecret(f[1])
		if err != nil {
			return "", false
		}
		return formatHex(key), true

	case "sign":
		keys, err := parseSecrets(f[1])
		if err != nil {
			return "", false
		}
		id, err := parseID(f[2])
		if err != nil {
			return "", false
		}
		if _, err := webhooks.ParseInt(f[3]); err != nil {
			return "", false
		}
		body, err := parseHex(f[4])
		if err != nil {
			return "", false
		}
		return webhooks.SignHeader(keys, id, f[3], body), true

	case "verify":
		keys, err := parseSecrets(f[1])
		if err != nil {
			return "", false
		}
		id, err := parseID(f[2])
		if err != nil {
			return "", false
		}
		if !printable(f[3], 64) {
			return "", false
		}
		now, err := webhooks.ParseInt(f[4])
		if err != nil {
			return "", false
		}
		header, err1 := parseHex(f[5])
		body, err2 := parseHex(f[6])
		if err1 != nil || err2 != nil {
			return "", false
		}
		m, err := webhooks.Verify(keys, id, f[3], string(header), body, now)
		if err != nil {
			return "fail " + err.Error(), true
		}
		return "ok " + itoa(m.Secret) + " " + itoa(m.Token), true
	}
	return "", false
}
