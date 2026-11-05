package command

import (
	"bytes"
	"sort"
	"strconv"

	"buildsys/kilnerr"
	"buildsys/vfs"
)

// Input is a file input captured when a command starts.
type Input struct {
	Path    string
	Content []byte
	Hash    uint64 // FNV-1a hash of Content
}

// Reader gives a command read access to other workspace files. It is used by
// preprocess to follow @need directives.
type Reader interface {
	Read(path string) ([]byte, bool)
}

// Result is what a successful command produces.
type Result struct {
	Out     []byte   // content of the declared output
	Depfile []byte   // content of the depfile (preprocess only)
	Deps    []string // discovered dependencies, sorted (preprocess only)
}

// Run executes the named command in-process. The command must have been
// validated against its Spec. Errors are execution errors (only preprocess
// can raise them).
func Run(name string, args []Arg, inputs []Input, files Reader) (Result, *kilnerr.Error) {
	switch name {
	case "write":
		return Result{Out: []byte(args[0].Str)}, nil
	case "copy":
		return Result{Out: inputs[0].Content}, nil
	case "concat":
		n := 0
		for _, in := range inputs {
			n += len(in.Content)
		}
		out := make([]byte, 0, n)
		for _, in := range inputs {
			out = append(out, in.Content...)
		}
		return Result{Out: out}, nil
	case "upper":
		return Result{Out: mapBytes(inputs[0].Content, 'a', 'z', 'A'-'a')}, nil
	case "lower":
		return Result{Out: mapBytes(inputs[0].Content, 'A', 'Z', 'a'-'A')}, nil
	case "grep":
		needle := []byte(args[0].Str)
		var out []byte
		eachLine(inputs[0].Content, func(l []byte) {
			if bytes.Contains(l, needle) {
				out = appendLine(out, l)
			}
		})
		return Result{Out: out}, nil
	case "replace":
		return Result{Out: Replace(inputs[0].Content, []byte(args[0].Str), []byte(args[1].Str))}, nil
	case "sort_lines":
		lines := splitLines(inputs[0].Content)
		sort.Slice(lines, func(i, j int) bool { return bytes.Compare(lines[i], lines[j]) < 0 })
		return Result{Out: joinLines(lines)}, nil
	case "reverse_lines":
		lines := splitLines(inputs[0].Content)
		for i, j := 0, len(lines)-1; i < j; i, j = i+1, j-1 {
			lines[i], lines[j] = lines[j], lines[i]
		}
		return Result{Out: joinLines(lines)}, nil
	case "dedup":
		seen := map[string]struct{}{}
		var out []byte
		eachLine(inputs[0].Content, func(l []byte) {
			if _, dup := seen[string(l)]; dup {
				return
			}
			seen[string(l)] = struct{}{}
			out = appendLine(out, l)
		})
		return Result{Out: out}, nil
	case "number":
		var out []byte
		n := 0
		eachLine(inputs[0].Content, func(l []byte) {
			n++
			out = strconv.AppendInt(out, int64(n), 10)
			out = append(out, ':', ' ')
			out = appendLine(out, l)
		})
		return Result{Out: out}, nil
	case "indent":
		pad := bytes.Repeat([]byte{' '}, int(args[0].Int))
		var out []byte
		eachLine(inputs[0].Content, func(l []byte) {
			out = append(out, pad...)
			out = appendLine(out, l)
		})
		return Result{Out: out}, nil
	case "wrap":
		c := inputs[0].Content
		out := make([]byte, 0, len(args[0].Str)+len(c)+len(args[1].Str))
		out = append(out, args[0].Str...)
		out = append(out, c...)
		out = append(out, args[1].Str...)
		return Result{Out: out}, nil
	case "count_lines":
		var out []byte
		total := 0
		for _, in := range inputs {
			n := CountLines(in.Content)
			total += n
			out = strconv.AppendInt(out, int64(n), 10)
			out = append(out, ' ')
			out = append(out, in.Path...)
			out = append(out, '\n')
		}
		out = strconv.AppendInt(out, int64(total), 10)
		out = append(out, " total\n"...)
		return Result{Out: out}, nil
	case "hash":
		var out []byte
		for _, in := range inputs {
			out = vfs.AppendHashHex(out, in.Hash)
			out = append(out, ' ')
			out = append(out, in.Path...)
			out = append(out, '\n')
		}
		return Result{Out: out}, nil
	case "preprocess":
		return preprocess(inputs[0], files)
	}
	panic("command: unknown command " + name)
}

// Replace returns c with every non-overlapping, left-to-right occurrence of
// from replaced by to. from must be non-empty.
func Replace(c, from, to []byte) []byte {
	out := make([]byte, 0, len(c))
	for {
		i := bytes.Index(c, from)
		if i < 0 {
			return append(out, c...)
		}
		out = append(out, c[:i]...)
		out = append(out, to...)
		c = c[i+len(from):]
	}
}

// CountLines returns the number of lines of c as defined by the spec.
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

func mapBytes(c []byte, lo, hi byte, delta int) []byte {
	out := make([]byte, len(c))
	for i, b := range c {
		if b >= lo && b <= hi {
			b = byte(int(b) + delta)
		}
		out[i] = b
	}
	return out
}

// eachLine calls fn with each line of c (without its newline), as views.
func eachLine(c []byte, fn func(line []byte)) {
	for len(c) > 0 {
		i := bytes.IndexByte(c, '\n')
		if i < 0 {
			fn(c)
			return
		}
		fn(c[:i])
		c = c[i+1:]
	}
}

func splitLines(c []byte) [][]byte {
	var lines [][]byte
	eachLine(c, func(l []byte) { lines = append(lines, l) })
	return lines
}

func appendLine(out, l []byte) []byte {
	out = append(out, l...)
	return append(out, '\n')
}

func joinLines(lines [][]byte) []byte {
	n := 0
	for _, l := range lines {
		n += len(l) + 1
	}
	out := make([]byte, 0, n)
	for _, l := range lines {
		out = appendLine(out, l)
	}
	return out
}

const needPrefix = "@need "

func preprocess(in Input, files Reader) (Result, *kilnerr.Error) {
	var out []byte
	discovered := map[string]struct{}{}
	stack := []string{in.Path}
	var expand func(p string, content []byte) *kilnerr.Error
	expand = func(p string, content []byte) *kilnerr.Error {
		var err *kilnerr.Error
		eachLineUntil(content, func(l []byte) bool {
			if len(l) > len(needPrefix) && string(l[:len(needPrefix)]) == needPrefix {
				q := string(l[len(needPrefix):])
				if !vfs.IsPath(q) {
					err = kilnerr.New(kilnerr.NeedPath, q)
					return false
				}
				qc, ok := files.Read(q)
				if !ok {
					err = kilnerr.New(kilnerr.NeedMissing, q+" needed by "+p)
					return false
				}
				for _, s := range stack {
					if s == q {
						err = kilnerr.New(kilnerr.NeedCycle, q)
						return false
					}
				}
				discovered[q] = struct{}{}
				stack = append(stack, q)
				err = expand(q, qc)
				stack = stack[:len(stack)-1]
				return err == nil
			}
			out = appendLine(out, l)
			return true
		})
		return err
	}
	if err := expand(in.Path, in.Content); err != nil {
		return Result{}, err
	}
	deps := make([]string, 0, len(discovered))
	for d := range discovered {
		deps = append(deps, d)
	}
	sort.Strings(deps)
	dep := []byte("kiln-deps 1\n")
	for _, d := range deps {
		dep = append(dep, "need "...)
		dep = append(dep, d...)
		dep = append(dep, '\n')
	}
	return Result{Out: out, Depfile: dep, Deps: deps}, nil
}

func eachLineUntil(c []byte, fn func(line []byte) bool) {
	for len(c) > 0 {
		i := bytes.IndexByte(c, '\n')
		if i < 0 {
			fn(c)
			return
		}
		if !fn(c[:i]) {
			return
		}
		c = c[i+1:]
	}
}
