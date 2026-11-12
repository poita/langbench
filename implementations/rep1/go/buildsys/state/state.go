// Package state reads and writes the .kiln-state file and decides whether a
// step is fresh with respect to it.
package state

import (
	"sort"
	"strings"

	"buildsys/plan"
	"buildsys/vfs"
)

// Header is the first line of every state file.
const Header = "kiln-state 1"

// PathHash is a workspace path with the hash of its content.
type PathHash struct {
	Path, Hash string
}

// Entry records what is known about one previously executed step.
type Entry struct {
	Key string // primary output path
	Cmd string // canonical command string
	In  []PathHash
	Dep []PathHash
	Out []PathHash
}

// State maps primary output paths to entries.
type State struct {
	entries map[string]*Entry
}

// New returns an empty state.
func New() *State { return &State{entries: map[string]*Entry{}} }

// Get returns the entry with the given key.
func (s *State) Get(key string) *Entry { return s.entries[key] }

// Put adds or replaces an entry.
func (s *State) Put(e *Entry) { s.entries[e.Key] = e }

// Delete removes the entry with the given key, if any.
func (s *State) Delete(key string) { delete(s.entries, key) }

// Len returns the number of entries.
func (s *State) Len() int { return len(s.entries) }

// Format renders the state file: entries sorted by key, every line terminated.
func (s *State) Format() string {
	keys := make([]string, 0, len(s.entries))
	for k := range s.entries {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(Header)
	b.WriteByte('\n')
	for _, k := range keys {
		e := s.entries[k]
		b.WriteString("step " + e.Key + "\n")
		b.WriteString("cmd " + e.Cmd + "\n")
		for _, sec := range []struct {
			tag  string
			list []PathHash
		}{{"in", e.In}, {"dep", e.Dep}, {"out", e.Out}} {
			for _, ph := range sec.list {
				b.WriteString(sec.tag + " " + ph.Path + " " + ph.Hash + "\n")
			}
		}
		b.WriteString("end\n")
	}
	return b.String()
}

func validHash(h string) bool {
	if len(h) != 16 {
		return false
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func parsePathHash(rest string) (PathHash, bool) {
	parts := strings.Split(rest, " ")
	if len(parts) != 2 || !vfs.ValidPath(parts[0]) || !validHash(parts[1]) {
		return PathHash{}, false
	}
	return PathHash{parts[0], parts[1]}, true
}

// Parse reads a state file. Any deviation from the format yields an empty
// state, as does an empty or unterminated file.
func Parse(content string) *State {
	if !strings.HasSuffix(content, "\n") {
		return New()
	}
	lines := strings.Split(content[:len(content)-1], "\n")
	if lines[0] != Header {
		return New()
	}
	st := New()
	i := 1
	for i < len(lines) {
		key, ok := strings.CutPrefix(lines[i], "step ")
		if !ok || !vfs.ValidPath(key) {
			return New()
		}
		i++
		e := &Entry{Key: key}
		if i >= len(lines) {
			return New()
		}
		cmd, ok := strings.CutPrefix(lines[i], "cmd ")
		if !ok || cmd == "" {
			return New()
		}
		e.Cmd = cmd
		i++
		for _, sec := range []struct {
			tag string
			dst *[]PathHash
		}{{"in ", &e.In}, {"dep ", &e.Dep}, {"out ", &e.Out}} {
			for i < len(lines) {
				rest, ok := strings.CutPrefix(lines[i], sec.tag)
				if !ok {
					break
				}
				ph, ok := parsePathHash(rest)
				if !ok {
					return New()
				}
				*sec.dst = append(*sec.dst, ph)
				i++
			}
		}
		if len(e.Out) == 0 || e.Out[0].Path != key || i >= len(lines) || lines[i] != "end" {
			return New()
		}
		i++
		if st.entries[key] != nil {
			return New()
		}
		st.entries[key] = e
	}
	return st
}

// Hasher gives the content hash of a workspace file.
type Hasher interface {
	Hash(path string) (string, bool)
}

func samePaths(rec []PathHash, want []string) bool {
	if len(rec) != len(want) {
		return false
	}
	for i := range rec {
		if rec[i].Path != want[i] {
			return false
		}
	}
	return true
}

func matches(rec []PathHash, fs Hasher) bool {
	for _, ph := range rec {
		if h, ok := fs.Hash(ph.Path); !ok || h != ph.Hash {
			return false
		}
	}
	return true
}

// Fresh reports whether step needs no re-execution given its state entry e
// (which may be nil) and the current workspace.
func Fresh(e *Entry, step *plan.Step, fs Hasher) bool {
	return e != nil &&
		e.Cmd == step.Command &&
		samePaths(e.Out, step.AllOutputs()) &&
		samePaths(e.In, step.FileInputs) &&
		matches(e.In, fs) && matches(e.Dep, fs) && matches(e.Out, fs)
}

// Capture builds the entry for a step that has just executed. discovered must
// be sorted.
func Capture(step *plan.Step, discovered []string, fs Hasher) *Entry {
	hashes := func(paths []string) []PathHash {
		var out []PathHash
		for _, p := range paths {
			h, _ := fs.Hash(p)
			out = append(out, PathHash{p, h})
		}
		return out
	}
	return &Entry{
		Key: step.Primary(),
		Cmd: step.Command,
		In:  hashes(step.FileInputs),
		Dep: hashes(discovered),
		Out: hashes(step.AllOutputs()),
	}
}
