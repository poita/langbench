package cmds

import (
	"bytes"
	"sort"
	"strconv"

	"buildsys/diag"
	"buildsys/vfs"
)

// Input is one file input of a command, captured when the command starts.
type Input struct {
	Path    string
	Content []byte
	Hash    uint64
}

// Reader gives `preprocess` access to files it discovers.
type Reader interface {
	Read(path string) ([]byte, bool)
}

// Result is what a successful command produced.
type Result struct {
	// Out is the content of the step's declared output.
	Out []byte
	// Depfile is the content of the depfile (nil unless the command has one).
	Depfile []byte
	// Deps lists the discovered dependencies in ascending order.
	Deps []string
}

// Execute runs c over its inputs. Errors are execution errors (E_NEED_*).
func Execute(c *Command, in []Input, files Reader) (Result, error) {
	var out []byte
	switch c.Spec.Name {
	case "write":
		out = []byte(c.Args[0].Str)
	case "copy":
		out = in[0].Content
	case "concat":
		n := 0
		for _, i := range in {
			n += len(i.Content)
		}
		out = make([]byte, 0, n)
		for _, i := range in {
			out = append(out, i.Content...)
		}
	case "upper":
		out = mapASCII(in[0].Content, 'a', 'z', 'A'-'a')
	case "lower":
		out = mapASCII(in[0].Content, 'A', 'Z', 'a'-'A')
	case "grep":
		needle := []byte(c.Args[0].Str)
		var b bytes.Buffer
		for _, l := range Lines(in[0].Content) {
			if bytes.Contains(l, needle) {
				b.Write(l)
				b.WriteByte('\n')
			}
		}
		out = b.Bytes()
	case "replace":
		out = ReplaceAll(in[0].Content, []byte(c.Args[0].Str), []byte(c.Args[1].Str))
	case "sort_lines":
		ls := Lines(in[0].Content)
		sort.SliceStable(ls, func(i, j int) bool { return bytes.Compare(ls[i], ls[j]) < 0 })
		out = JoinLines(ls)
	case "reverse_lines":
		ls := Lines(in[0].Content)
		for i, j := 0, len(ls)-1; i < j; i, j = i+1, j-1 {
			ls[i], ls[j] = ls[j], ls[i]
		}
		out = JoinLines(ls)
	case "dedup":
		seen := make(map[string]struct{})
		var keep [][]byte
		for _, l := range Lines(in[0].Content) {
			if _, dup := seen[string(l)]; dup {
				continue
			}
			seen[string(l)] = struct{}{}
			keep = append(keep, l)
		}
		out = JoinLines(keep)
	case "number":
		var b bytes.Buffer
		for i, l := range Lines(in[0].Content) {
			b.WriteString(strconv.Itoa(i + 1))
			b.WriteString(": ")
			b.Write(l)
			b.WriteByte('\n')
		}
		out = b.Bytes()
	case "indent":
		pad := bytes.Repeat([]byte{' '}, int(c.Args[0].Int))
		var b bytes.Buffer
		for _, l := range Lines(in[0].Content) {
			b.Write(pad)
			b.Write(l)
			b.WriteByte('\n')
		}
		out = b.Bytes()
	case "wrap":
		p, s := c.Args[0].Str, c.Args[1].Str
		out = make([]byte, 0, len(p)+len(in[0].Content)+len(s))
		out = append(out, p...)
		out = append(out, in[0].Content...)
		out = append(out, s...)
	case "count_lines":
		var b bytes.Buffer
		total := 0
		for _, i := range in {
			n := CountLines(i.Content)
			total += n
			b.WriteString(strconv.Itoa(n))
			b.WriteByte(' ')
			b.WriteString(i.Path)
			b.WriteByte('\n')
		}
		b.WriteString(strconv.Itoa(total))
		b.WriteString(" total\n")
		out = b.Bytes()
	case "hash":
		var b bytes.Buffer
		for _, i := range in {
			b.WriteString(vfs.HexHash(i.Hash))
			b.WriteByte(' ')
			b.WriteString(i.Path)
			b.WriteByte('\n')
		}
		out = b.Bytes()
	case "preprocess":
		return preprocess(in[0], files)
	}
	return Result{Out: out}, nil
}

func mapASCII(src []byte, lo, hi byte, delta int) []byte {
	out := make([]byte, len(src))
	for i, c := range src {
		if c >= lo && c <= hi {
			c = byte(int(c) + delta)
		}
		out[i] = c
	}
	return out
}

// Lines splits content into lines as defined by the specification: no lines
// for empty content, otherwise split at every '\n' dropping a final empty
// piece. The returned slices are views into content.
func Lines(c []byte) [][]byte {
	if len(c) == 0 {
		return nil
	}
	ls := make([][]byte, 0, bytes.Count(c, []byte{'\n'})+1)
	for len(c) > 0 {
		i := bytes.IndexByte(c, '\n')
		if i < 0 {
			ls = append(ls, c)
			break
		}
		ls = append(ls, c[:i])
		c = c[i+1:]
	}
	return ls
}

// CountLines returns len(Lines(c)) without allocating.
func CountLines(c []byte) int {
	if len(c) == 0 {
		return 0
	}
	n := bytes.Count(c, []byte{'\n'})
	if c[len(c)-1] != '\n' {
		n++
	}
	return n
}

// JoinLines concatenates lines, each followed by one '\n'.
func JoinLines(ls [][]byte) []byte {
	n := 0
	for _, l := range ls {
		n += len(l) + 1
	}
	out := make([]byte, 0, n)
	for _, l := range ls {
		out = append(out, l...)
		out = append(out, '\n')
	}
	return out
}

// ReplaceAll replaces every non-overlapping occurrence of from (non-empty) in
// s with to, scanning left to right.
func ReplaceAll(s, from, to []byte) []byte {
	var b bytes.Buffer
	for len(s) > 0 {
		i := bytes.Index(s, from)
		if i < 0 {
			break
		}
		b.Write(s[:i])
		b.Write(to)
		s = s[i+len(from):]
	}
	b.Write(s)
	return b.Bytes()
}

var needPrefix = []byte("@need ")

type expander struct {
	files Reader
	stack []string
	found map[string]struct{}
	out   bytes.Buffer
}

func preprocess(primary Input, files Reader) (Result, error) {
	e := &expander{files: files, found: make(map[string]struct{})}
	if err := e.expand(primary.Path, primary.Content); err != nil {
		return Result{}, err
	}
	deps := make([]string, 0, len(e.found))
	for p := range e.found {
		deps = append(deps, p)
	}
	sort.Strings(deps)
	var d bytes.Buffer
	d.WriteString("kiln-deps 1\n")
	for _, p := range deps {
		d.WriteString("need ")
		d.WriteString(p)
		d.WriteByte('\n')
	}
	return Result{Out: e.out.Bytes(), Depfile: d.Bytes(), Deps: deps}, nil
}

func (e *expander) expand(path string, content []byte) error {
	e.stack = append(e.stack, path)
	defer func() { e.stack = e.stack[:len(e.stack)-1] }()
	for _, l := range Lines(content) {
		if !bytes.HasPrefix(l, needPrefix) || len(l) == len(needPrefix) {
			e.out.Write(l)
			e.out.WriteByte('\n')
			continue
		}
		q := string(l[len(needPrefix):])
		if !vfs.IsWorkspacePath(q) {
			return diag.New(diag.NeedPath, "%s", q)
		}
		sub, ok := e.files.Read(q)
		if !ok {
			return diag.New(diag.NeedMissing, "%s needed by %s", q, path)
		}
		for _, s := range e.stack {
			if s == q {
				return diag.New(diag.NeedCycle, "%s", q)
			}
		}
		e.found[q] = struct{}{}
		if err := e.expand(q, sub); err != nil {
			return err
		}
	}
	return nil
}
