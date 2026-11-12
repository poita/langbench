// Package state reads, writes and queries Kiln's persistent build state: the
// `.kiln-state` file that records, for every executed step, its command, the
// content hashes of its inputs, discovered dependencies and outputs.
package state

import (
	"sort"
	"strings"

	"buildsys/vfs"
)

// Header is the first line of a state file.
const Header = "kiln-state 1"

// PathHash is a path together with the hash of the content seen at it.
type PathHash struct {
	Path string
	Hash uint64
}

// Entry is the recorded state of one step, keyed by its primary output.
type Entry struct {
	Step string
	Cmd  string
	In   []PathHash
	Dep  []PathHash
	Out  []PathHash
}

// State is a set of entries keyed by primary output path.
type State struct {
	entries map[string]*Entry
}

// New returns an empty state.
func New() *State { return &State{entries: map[string]*Entry{}} }

// Get returns the entry for the step with the given primary output.
func (s *State) Get(step string) (*Entry, bool) {
	e, ok := s.entries[step]
	return e, ok
}

// Put adds or replaces an entry.
func (s *State) Put(e *Entry) { s.entries[e.Step] = e }

// Remove deletes the entry for a step, if any.
func (s *State) Remove(step string) { delete(s.entries, step) }

// Len returns the number of entries.
func (s *State) Len() int { return len(s.entries) }

// Serialize renders the state file: entries sorted by primary output.
func (s *State) Serialize() string {
	keys := make([]string, 0, len(s.entries))
	for k := range s.entries {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(Header + "\n")
	for _, k := range keys {
		e := s.entries[k]
		b.WriteString("step " + e.Step + "\n")
		b.WriteString("cmd " + e.Cmd + "\n")
		for _, p := range e.In {
			b.WriteString("in " + p.Path + " " + vfs.HashString(p.Hash) + "\n")
		}
		for _, p := range e.Dep {
			b.WriteString("dep " + p.Path + " " + vfs.HashString(p.Hash) + "\n")
		}
		for _, p := range e.Out {
			b.WriteString("out " + p.Path + " " + vfs.HashString(p.Hash) + "\n")
		}
		b.WriteString("end\n")
	}
	return b.String()
}

// Parse reads a state file. Any deviation from the format yields an empty
// state, as does a missing file (data == nil handled by the caller via ok).
func Parse(data string) *State {
	if s, ok := parse(data); ok {
		return s
	}
	return New()
}

func parse(data string) (*State, bool) {
	if !strings.HasSuffix(data, "\n") {
		return nil, false
	}
	lines := strings.Split(data[:len(data)-1], "\n")
	if lines[0] != Header {
		return nil, false
	}
	st := New()
	lines = lines[1:]
	for i := 0; i < len(lines); {
		key, rest, ok := splitKey(lines[i])
		if !ok || key != "step" || !vfs.ValidPath(rest) {
			return nil, false
		}
		e := &Entry{Step: rest}
		i++
		// cmd: exactly one.
		if i >= len(lines) {
			return nil, false
		}
		key, rest, ok = splitKey(lines[i])
		if !ok || key != "cmd" || rest == "" {
			return nil, false
		}
		e.Cmd = rest
		i++
		sections := []struct {
			key string
			dst *[]PathHash
		}{{"in", &e.In}, {"dep", &e.Dep}, {"out", &e.Out}}
		for _, sec := range sections {
			for i < len(lines) {
				key, rest, ok = splitKey(lines[i])
				if !ok || key != sec.key {
					break
				}
				ph, ok := parsePathHash(rest)
				if !ok {
					return nil, false
				}
				*sec.dst = append(*sec.dst, ph)
				i++
			}
		}
		if len(e.Out) == 0 || i >= len(lines) || lines[i] != "end" {
			return nil, false
		}
		i++
		if e.Out[0].Path != e.Step {
			return nil, false
		}
		if _, dup := st.entries[e.Step]; dup {
			return nil, false
		}
		st.entries[e.Step] = e
	}
	return st, true
}

// splitKey splits "key remainder" at the first space.
func splitKey(line string) (key, rest string, ok bool) {
	i := strings.IndexByte(line, ' ')
	if i < 0 {
		return "", "", false
	}
	return line[:i], line[i+1:], true
}

func parsePathHash(s string) (PathHash, bool) {
	i := strings.IndexByte(s, ' ')
	if i < 0 {
		return PathHash{}, false
	}
	path, hex := s[:i], s[i+1:]
	if !vfs.ValidPath(path) {
		return PathHash{}, false
	}
	h, ok := vfs.ParseHash(hex)
	if !ok {
		return PathHash{}, false
	}
	return PathHash{Path: path, Hash: h}, true
}

// Fresh decides whether a step is up to date with respect to its state entry
// e (which may be nil) and the file system. canonical is the step's canonical
// command string, fileInputs its file inputs and fullOutputs its output list.
func Fresh(e *Entry, canonical string, fileInputs, fullOutputs []string, fs *vfs.FS) bool {
	if e == nil || e.Cmd != canonical {
		return false
	}
	if !samePaths(e.Out, fullOutputs) || !samePaths(e.In, fileInputs) {
		return false
	}
	for _, list := range [][]PathHash{e.In, e.Dep, e.Out} {
		for _, p := range list {
			f := fs.Get(p.Path)
			if f == nil || f.Hash() != p.Hash {
				return false
			}
		}
	}
	return true
}

func samePaths(have []PathHash, want []string) bool {
	if len(have) != len(want) {
		return false
	}
	for i := range have {
		if have[i].Path != want[i] {
			return false
		}
	}
	return true
}
