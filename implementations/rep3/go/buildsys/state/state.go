// Package state reads and writes the `.kiln-state` file, in which Kiln
// persists what it knows about previously executed steps.
package state

import (
	"bytes"
	"sort"

	"buildsys/vfs"
)

// Header is the first line of every state file.
const Header = "kiln-state 1"

// PathHash is a workspace path with the content hash recorded for it.
type PathHash struct {
	Path string
	Hash uint64
}

// Entry records one executed step.
type Entry struct {
	Cmd  string
	Ins  []PathHash
	Deps []PathHash
	Outs []PathHash
}

// State maps a step's primary output path to its entry.
type State map[string]*Entry

// Parse reads a state file. Any deviation from the grammar yields an empty
// state, as the specification requires.
func Parse(data []byte) State {
	st, ok := parse(data)
	if !ok {
		return State{}
	}
	return st
}

type phase uint8

const (
	phStart phase = iota // expecting `step` or EOF
	phCmd                // after `step`, expecting `cmd`
	phIn                 // after `cmd`: in*, dep*, out+
	phDep
	phOut
)

func parse(data []byte) (State, bool) {
	if len(data) == 0 || data[len(data)-1] != '\n' {
		return nil, false
	}
	st := State{}
	first := true
	ph := phStart
	var cur *Entry
	var key string
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		line := data[:i]
		data = data[i+1:]
		if first {
			if string(line) != Header {
				return nil, false
			}
			first = false
			continue
		}
		if string(line) == "end" {
			if ph != phOut {
				return nil, false
			}
			if cur.Outs[0].Path != key {
				return nil, false
			}
			if _, dup := st[key]; dup {
				return nil, false
			}
			st[key] = cur
			cur, ph = nil, phStart
			continue
		}
		sp := bytes.IndexByte(line, ' ')
		if sp < 0 {
			return nil, false
		}
		k, rest := string(line[:sp]), line[sp+1:]
		switch k {
		case "step":
			if ph != phStart || !vfs.IsWorkspacePath(string(rest)) {
				return nil, false
			}
			key, cur, ph = string(rest), &Entry{}, phCmd
		case "cmd":
			if ph != phCmd || len(rest) == 0 {
				return nil, false
			}
			cur.Cmd, ph = string(rest), phIn
		case "in", "dep", "out":
			want := phOut
			switch k {
			case "in":
				want = phIn
			case "dep":
				want = phDep
			}
			if ph < phIn || want < ph {
				return nil, false
			}
			ph = want
			sp2 := bytes.IndexByte(rest, ' ')
			if sp2 < 0 {
				return nil, false
			}
			path := string(rest[:sp2])
			h, ok := vfs.ParseHexHash(string(rest[sp2+1:]))
			if !ok || !vfs.IsWorkspacePath(path) {
				return nil, false
			}
			entry := PathHash{path, h}
			switch k {
			case "in":
				cur.Ins = append(cur.Ins, entry)
			case "dep":
				cur.Deps = append(cur.Deps, entry)
			default:
				cur.Outs = append(cur.Outs, entry)
			}
		default:
			return nil, false
		}
	}
	if first || ph != phStart {
		return nil, false
	}
	return st, true
}

// Encode renders the state in canonical form: entries sorted by primary output.
func (s State) Encode() []byte {
	keys := make([]string, 0, len(s))
	for k := range s {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b bytes.Buffer
	b.WriteString(Header)
	b.WriteByte('\n')
	for _, k := range keys {
		e := s[k]
		b.WriteString("step ")
		b.WriteString(k)
		b.WriteString("\ncmd ")
		b.WriteString(e.Cmd)
		b.WriteByte('\n')
		for _, group := range []struct {
			name string
			list []PathHash
		}{{"in", e.Ins}, {"dep", e.Deps}, {"out", e.Outs}} {
			for _, ph := range group.list {
				b.WriteString(group.name)
				b.WriteByte(' ')
				b.WriteString(ph.Path)
				b.WriteByte(' ')
				b.WriteString(vfs.HexHash(ph.Hash))
				b.WriteByte('\n')
			}
		}
		b.WriteString("end\n")
	}
	return b.Bytes()
}

// Hasher gives the current content hash of workspace files.
type Hasher interface {
	Hash(path string) (uint64, bool)
}

// Fresh reports whether an entry still describes a step with the given
// canonical command, file inputs and full output list, and every file it
// recorded still has the recorded content hash.
func (e *Entry) Fresh(cmd string, fileInputs, fullOuts []string, files Hasher) bool {
	if e == nil || e.Cmd != cmd {
		return false
	}
	if !samePaths(e.Outs, fullOuts) || !samePaths(e.Ins, fileInputs) {
		return false
	}
	for _, group := range [][]PathHash{e.Ins, e.Deps, e.Outs} {
		for _, ph := range group {
			if h, ok := files.Hash(ph.Path); !ok || h != ph.Hash {
				return false
			}
		}
	}
	return true
}

func samePaths(a []PathHash, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Path != b[i] {
			return false
		}
	}
	return true
}
