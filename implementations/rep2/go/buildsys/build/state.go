package build

import (
	"sort"
	"strings"

	"kiln/kbl"
	"kiln/vfs"
)

// PathHash is a workspace path with the content hash recorded for it.
type PathHash struct {
	Path string
	Hash uint64
}

// Entry is the persisted record of one executed step.
type Entry struct {
	Cmd  string
	Ins  []PathHash
	Deps []PathHash
	Outs []PathHash
}

// State is the parsed content of .kiln-state, keyed by primary output path.
type State struct {
	Entries map[string]*Entry
}

// NewState returns an empty state.
func NewState() *State { return &State{Entries: map[string]*Entry{}} }

const stateHeader = "kiln-state 1"

// ParseState reads a state file. Any deviation from the format yields an
// empty state, exactly as the specification requires.
func ParseState(data []byte) *State {
	st := parseState(string(data))
	if st == nil {
		return NewState()
	}
	return st
}

func parsePathHash(rest string) (PathHash, bool) {
	i := strings.IndexByte(rest, ' ')
	if i < 0 || !vfs.ValidPath(rest[:i]) {
		return PathHash{}, false
	}
	h, ok := vfs.ParseHashHex(rest[i+1:])
	if !ok {
		return PathHash{}, false
	}
	return PathHash{Path: rest[:i], Hash: h}, true
}

func parseState(s string) *State {
	if len(s) == 0 || s[len(s)-1] != '\n' {
		return nil
	}
	s = s[:len(s)-1]
	lines := strings.Split(s, "\n")
	if lines[0] != stateHeader {
		return nil
	}
	st := NewState()
	var cur *Entry
	var key string
	section := 0 // 0: expecting cmd, 1: in, 2: dep, 3: out
	for _, line := range lines[1:] {
		if cur == nil {
			rest, ok := strings.CutPrefix(line, "step ")
			if !ok || !vfs.ValidPath(rest) {
				return nil
			}
			if _, dup := st.Entries[rest]; dup {
				return nil
			}
			key = rest
			cur = &Entry{}
			section = 0
			continue
		}
		if line == "end" {
			if len(cur.Outs) == 0 || section == 0 || cur.Outs[0].Path != key {
				return nil
			}
			st.Entries[key] = cur
			cur = nil
			continue
		}
		i := strings.IndexByte(line, ' ')
		if i < 0 {
			return nil
		}
		k, rest := line[:i], line[i+1:]
		switch k {
		case "cmd":
			if section != 0 || rest == "" {
				return nil
			}
			cur.Cmd = rest
			section = 1
		case "in", "dep", "out":
			want := map[string]int{"in": 1, "dep": 2, "out": 3}[k]
			if section == 0 || want < section {
				return nil
			}
			ph, ok := parsePathHash(rest)
			if !ok {
				return nil
			}
			section = want
			switch k {
			case "in":
				cur.Ins = append(cur.Ins, ph)
			case "dep":
				cur.Deps = append(cur.Deps, ph)
			default:
				cur.Outs = append(cur.Outs, ph)
			}
		default:
			return nil
		}
	}
	if cur != nil {
		return nil
	}
	return st
}

// Encode renders the state in canonical form: entries sorted by primary
// output path.
func (st *State) Encode() []byte {
	keys := make([]string, 0, len(st.Entries))
	for k := range st.Entries {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	b := make([]byte, 0, 64+len(keys)*128)
	b = append(b, stateHeader...)
	b = append(b, '\n')
	emit := func(tag string, l []PathHash) {
		for _, ph := range l {
			b = append(b, tag...)
			b = append(b, ' ')
			b = append(b, ph.Path...)
			b = append(b, ' ')
			b = append(b, vfs.HashHex(ph.Hash)...)
			b = append(b, '\n')
		}
	}
	for _, k := range keys {
		e := st.Entries[k]
		b = append(b, "step "...)
		b = append(b, k...)
		b = append(b, "\ncmd "...)
		b = append(b, e.Cmd...)
		b = append(b, '\n')
		emit("in", e.Ins)
		emit("dep", e.Deps)
		emit("out", e.Outs)
		b = append(b, "end\n"...)
	}
	return b
}

// current reports whether every recorded hash still matches the workspace.
func current(fs *vfs.FS, l []PathHash) bool {
	for _, ph := range l {
		h, ok := fs.Hash(ph.Path)
		if !ok || h != ph.Hash {
			return false
		}
	}
	return true
}

func samePaths(l []PathHash, paths []string) bool {
	if len(l) != len(paths) {
		return false
	}
	for i := range l {
		if l[i].Path != paths[i] {
			return false
		}
	}
	return true
}

// Fresh decides whether step s is a cache hit: it has a state entry whose
// command, output list and input list match and whose recorded inputs,
// discovered dependencies and outputs all still have the recorded content.
func (st *State) Fresh(fs *vfs.FS, s *kbl.Step) bool {
	e, ok := st.Entries[s.Primary()]
	if !ok || e.Cmd != s.CmdStr {
		return false
	}
	if !samePaths(e.Outs, s.FullOutputs()) || !samePaths(e.Ins, s.FileIns) {
		return false
	}
	return current(fs, e.Ins) && current(fs, e.Deps) && current(fs, e.Outs)
}
