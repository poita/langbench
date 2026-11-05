// Package state reads and writes the .kiln-state file, the persisted record
// of previously executed steps used for change detection.
package state

import (
	"bytes"
	"sort"

	"buildsys/vfs"
)

// Header is the first line of every state file.
const Header = "kiln-state 1"

// PathHash is a workspace path with the hash of the content seen there.
type PathHash struct {
	Path string
	Hash uint64
}

// Entry records one executed step.
type Entry struct {
	Cmd string
	In  []PathHash
	Dep []PathHash
	Out []PathHash
}

// State maps a step's primary output path to its entry.
type State map[string]*Entry

// Parse reads a state file. Any deviation from the grammar yields an empty
// State (ok is false), as does a missing trailing newline.
func Parse(data []byte) (st State, ok bool) {
	if len(data) == 0 || data[len(data)-1] != '\n' {
		return State{}, false
	}
	st = State{}
	pos := 0
	next := func() ([]byte, bool) {
		if pos >= len(data) {
			return nil, false
		}
		i := bytes.IndexByte(data[pos:], '\n')
		line := data[pos : pos+i]
		pos += i + 1
		return line, true
	}
	first, _ := next()
	if string(first) != Header {
		return State{}, false
	}
	for {
		line, more := next()
		if !more {
			return st, true
		}
		key, rest, okk := splitKey(line)
		if !okk || key != "step" || !vfs.IsPath(rest) {
			return State{}, false
		}
		if _, dup := st[rest]; dup {
			return State{}, false
		}
		e := &Entry{}
		// cmd
		line, more = next()
		if !more {
			return State{}, false
		}
		key, rest2, okk := splitKey(line)
		if !okk || key != "cmd" || rest2 == "" {
			return State{}, false
		}
		e.Cmd = rest2
		// in*, dep*, out+ , end
		phase := 0 // 0=in, 1=dep, 2=out
		for done := false; !done; {
			line, more = next()
			if !more {
				return State{}, false
			}
			if string(line) == "end" {
				done = true
				continue
			}
			k, r, okk := splitKey(line)
			if !okk {
				return State{}, false
			}
			ph, okp := parsePathHash(r)
			if !okp {
				return State{}, false
			}
			switch k {
			case "in":
				if phase > 0 {
					return State{}, false
				}
				e.In = append(e.In, ph)
			case "dep":
				if phase > 1 {
					return State{}, false
				}
				phase = 1
				e.Dep = append(e.Dep, ph)
			case "out":
				phase = 2
				e.Out = append(e.Out, ph)
			default:
				return State{}, false
			}
		}
		if len(e.Out) == 0 || e.Out[0].Path != rest {
			return State{}, false
		}
		st[rest] = e
	}
}

func splitKey(line []byte) (key, rest string, ok bool) {
	i := bytes.IndexByte(line, ' ')
	if i < 0 {
		return "", "", false
	}
	return string(line[:i]), string(line[i+1:]), true
}

func parsePathHash(s string) (PathHash, bool) {
	for i := 0; i < len(s); i++ {
		if s[i] == ' ' {
			h, ok := vfs.ParseHashHex(s[i+1:])
			if !ok || !vfs.IsPath(s[:i]) {
				return PathHash{}, false
			}
			return PathHash{Path: s[:i], Hash: h}, true
		}
	}
	return PathHash{}, false
}

// Marshal renders the state in canonical form: entries sorted by key.
func (st State) Marshal() []byte {
	keys := make([]string, 0, len(st))
	for k := range st {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b []byte
	b = append(b, Header...)
	b = append(b, '\n')
	line := func(kind string, ph PathHash) {
		b = append(b, kind...)
		b = append(b, ' ')
		b = append(b, ph.Path...)
		b = append(b, ' ')
		b = vfs.AppendHashHex(b, ph.Hash)
		b = append(b, '\n')
	}
	for _, k := range keys {
		e := st[k]
		b = append(b, "step "...)
		b = append(b, k...)
		b = append(b, "\ncmd "...)
		b = append(b, e.Cmd...)
		b = append(b, '\n')
		for _, p := range e.In {
			line("in", p)
		}
		for _, p := range e.Dep {
			line("dep", p)
		}
		for _, p := range e.Out {
			line("out", p)
		}
		b = append(b, "end\n"...)
	}
	return b
}
