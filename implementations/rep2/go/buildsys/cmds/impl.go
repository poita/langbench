package cmds

import (
	"bytes"
	"sort"
	"strconv"

	"kiln/errs"
	"kiln/vfs"
)

// forEachLine calls f with every line of data (see "Lines of a file" in the
// specification): split at 0x0A, with a final empty piece discarded.
func forEachLine(data []byte, f func(line []byte)) {
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			f(data)
			return
		}
		f(data[:i])
		data = data[i+1:]
	}
}

func lines(data []byte) [][]byte {
	var out [][]byte
	forEachLine(data, func(l []byte) { out = append(out, l) })
	return out
}

func simple(f func(a []Arg, in []Input) []byte) func([]Arg, []Input, Source) (Result, *errs.Error) {
	return func(a []Arg, in []Input, _ Source) (Result, *errs.Error) {
		return Result{Output: f(a, in)}, nil
	}
}

// ReplaceAll replaces every non-overlapping occurrence of from (scanning
// left to right) in s with to. from must be non-empty.
func ReplaceAll(s []byte, from, to string) []byte {
	out := make([]byte, 0, len(s))
	f := []byte(from)
	for len(s) > 0 {
		i := bytes.Index(s, f)
		if i < 0 {
			break
		}
		out = append(out, s[:i]...)
		out = append(out, to...)
		s = s[i+len(f):]
	}
	return append(out, s...)
}

func mapBytes(data []byte, lo, hi byte, delta byte) []byte {
	out := make([]byte, len(data))
	for i, c := range data {
		if c >= lo && c <= hi {
			c ^= delta
		}
		out[i] = c
	}
	return out
}

func init() {
	register(&Spec{Name: "write", Params: []ArgKind{Str}, MinIn: 0, MaxIn: 0, DefaultCost: 1,
		run: simple(func(a []Arg, in []Input) []byte { return []byte(a[0].S) })})
	register(&Spec{Name: "copy", MinIn: 1, MaxIn: 1, DefaultCost: 1,
		run: simple(func(a []Arg, in []Input) []byte { return in[0].Data })})
	register(&Spec{Name: "concat", MinIn: 1, MaxIn: Unbounded, DefaultCost: 2,
		run: simple(func(a []Arg, in []Input) []byte {
			n := 0
			for _, i := range in {
				n += len(i.Data)
			}
			out := make([]byte, 0, n)
			for _, i := range in {
				out = append(out, i.Data...)
			}
			return out
		})})
	register(&Spec{Name: "upper", MinIn: 1, MaxIn: 1, DefaultCost: 2,
		run: simple(func(a []Arg, in []Input) []byte { return mapBytes(in[0].Data, 'a', 'z', 0x20) })})
	register(&Spec{Name: "lower", MinIn: 1, MaxIn: 1, DefaultCost: 2,
		run: simple(func(a []Arg, in []Input) []byte { return mapBytes(in[0].Data, 'A', 'Z', 0x20) })})
	register(&Spec{Name: "grep", Params: []ArgKind{Str}, MinIn: 1, MaxIn: 1, DefaultCost: 3,
		run: simple(func(a []Arg, in []Input) []byte {
			needle := []byte(a[0].S)
			var out []byte
			forEachLine(in[0].Data, func(l []byte) {
				if bytes.Contains(l, needle) {
					out = append(out, l...)
					out = append(out, '\n')
				}
			})
			return out
		})})
	register(&Spec{Name: "replace", Params: []ArgKind{Str, Str}, MinIn: 1, MaxIn: 1, DefaultCost: 3,
		run: simple(func(a []Arg, in []Input) []byte { return ReplaceAll(in[0].Data, a[0].S, a[1].S) })})
	register(&Spec{Name: "sort_lines", MinIn: 1, MaxIn: 1, DefaultCost: 4,
		run: simple(func(a []Arg, in []Input) []byte {
			ls := lines(in[0].Data)
			sort.Slice(ls, func(i, j int) bool { return bytes.Compare(ls[i], ls[j]) < 0 })
			return joinLines(ls, len(in[0].Data)+1)
		})})
	register(&Spec{Name: "reverse_lines", MinIn: 1, MaxIn: 1, DefaultCost: 2,
		run: simple(func(a []Arg, in []Input) []byte {
			ls := lines(in[0].Data)
			for i, j := 0, len(ls)-1; i < j; i, j = i+1, j-1 {
				ls[i], ls[j] = ls[j], ls[i]
			}
			return joinLines(ls, len(in[0].Data)+1)
		})})
	register(&Spec{Name: "dedup", MinIn: 1, MaxIn: 1, DefaultCost: 3,
		run: simple(func(a []Arg, in []Input) []byte {
			seen := map[string]struct{}{}
			out := make([]byte, 0, len(in[0].Data))
			forEachLine(in[0].Data, func(l []byte) {
				if _, dup := seen[string(l)]; dup {
					return
				}
				seen[string(l)] = struct{}{}
				out = append(out, l...)
				out = append(out, '\n')
			})
			return out
		})})
	register(&Spec{Name: "number", MinIn: 1, MaxIn: 1, DefaultCost: 2,
		run: simple(func(a []Arg, in []Input) []byte {
			var out []byte
			n := 0
			forEachLine(in[0].Data, func(l []byte) {
				n++
				out = strconv.AppendInt(out, int64(n), 10)
				out = append(out, ':', ' ')
				out = append(out, l...)
				out = append(out, '\n')
			})
			return out
		})})
	register(&Spec{Name: "indent", Params: []ArgKind{Int}, MinIn: 1, MaxIn: 1, DefaultCost: 2,
		run: simple(func(a []Arg, in []Input) []byte {
			pad := bytes.Repeat([]byte{' '}, int(a[0].I))
			var out []byte
			forEachLine(in[0].Data, func(l []byte) {
				out = append(out, pad...)
				out = append(out, l...)
				out = append(out, '\n')
			})
			return out
		})})
	register(&Spec{Name: "wrap", Params: []ArgKind{Str, Str}, MinIn: 1, MaxIn: 1, DefaultCost: 1,
		run: simple(func(a []Arg, in []Input) []byte {
			out := make([]byte, 0, len(a[0].S)+len(in[0].Data)+len(a[1].S))
			out = append(out, a[0].S...)
			out = append(out, in[0].Data...)
			return append(out, a[1].S...)
		})})
	register(&Spec{Name: "count_lines", MinIn: 1, MaxIn: Unbounded, DefaultCost: 2,
		run: simple(func(a []Arg, in []Input) []byte {
			var out []byte
			total := 0
			for _, i := range in {
				n := countLines(i.Data)
				total += n
				out = strconv.AppendInt(out, int64(n), 10)
				out = append(out, ' ')
				out = append(out, i.Path...)
				out = append(out, '\n')
			}
			out = strconv.AppendInt(out, int64(total), 10)
			return append(out, " total\n"...)
		})})
	register(&Spec{Name: "hash", MinIn: 1, MaxIn: Unbounded, DefaultCost: 3,
		run: simple(func(a []Arg, in []Input) []byte {
			var out []byte
			for _, i := range in {
				out = hashLine(out, i.Hash, i.Path)
			}
			return out
		})})
	register(&Spec{Name: "preprocess", MinIn: 1, MaxIn: 1, Depfile: true, DefaultCost: 6, run: preprocess})
}

func countLines(data []byte) int {
	if len(data) == 0 {
		return 0
	}
	n := bytes.Count(data, []byte{'\n'})
	if data[len(data)-1] != '\n' {
		n++
	}
	return n
}

func joinLines(ls [][]byte, hint int) []byte {
	out := make([]byte, 0, hint)
	for _, l := range ls {
		out = append(out, l...)
		out = append(out, '\n')
	}
	return out
}

var needPrefix = []byte("@need ")

type expander struct {
	src   Source
	out   []byte
	stack []string
	seen  map[string]uint64
}

func (e *expander) expand(path string, data []byte) *errs.Error {
	e.stack = append(e.stack, path)
	var err *errs.Error
	forEachLine(data, func(l []byte) {
		if err != nil {
			return
		}
		if len(l) > len(needPrefix) && bytes.HasPrefix(l, needPrefix) {
			q := string(l[len(needPrefix):])
			if !vfs.ValidPath(q) {
				err = errs.New(errs.NeedPath, "%s", q)
				return
			}
			d, h, ok := e.src.Lookup(q)
			if !ok {
				err = errs.New(errs.NeedMissing, "%s needed by %s", q, path)
				return
			}
			for _, s := range e.stack {
				if s == q {
					err = errs.New(errs.NeedCycle, "%s", q)
					return
				}
			}
			e.seen[q] = h
			err = e.expand(q, d)
			return
		}
		e.out = append(e.out, l...)
		e.out = append(e.out, '\n')
	})
	e.stack = e.stack[:len(e.stack)-1]
	return err
}

func preprocess(a []Arg, in []Input, src Source) (Result, *errs.Error) {
	e := &expander{src: src, seen: map[string]uint64{}}
	if err := e.expand(in[0].Path, in[0].Data); err != nil {
		return Result{}, err
	}
	deps := make([]Dep, 0, len(e.seen))
	for p, h := range e.seen {
		deps = append(deps, Dep{Path: p, Hash: h})
	}
	sort.Slice(deps, func(i, j int) bool { return deps[i].Path < deps[j].Path })
	df := []byte("kiln-deps 1\n")
	for _, d := range deps {
		df = append(df, "need "...)
		df = append(df, d.Path...)
		df = append(df, '\n')
	}
	return Result{Output: e.out, Depfile: df, Deps: deps}, nil
}
