// Package vfs implements the virtual file system a Kiln session runs against:
// a flat map from workspace paths to file contents, with cached FNV-1a content
// hashes and a sorted index of the paths eligible for glob matching.
package vfs

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// StateFile is the workspace path of the persisted build state.
const StateFile = ".kiln-state"

// OutDir is the first component of every generated path.
const OutDir = "out"

const (
	fnvOffset = 0xcbf29ce484222325
	fnvPrime  = 0x100000001b3
	hexDigits = "0123456789abcdef"
)

// Hash returns the 64-bit FNV-1a hash of s as 16 lowercase hex digits.
func Hash(s string) string {
	h := uint64(fnvOffset)
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= fnvPrime
	}
	var buf [16]byte
	for i := 15; i >= 0; i-- {
		buf[i] = hexDigits[h&0xf]
		h >>= 4
	}
	return string(buf[:])
}

func isPChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '_' || c == '.' || c == '+' || c == '-'
}

// ValidPath reports whether p is a workspace path.
func ValidPath(p string) bool {
	if p == "" || len(p) > 1024 {
		return false
	}
	start := 0
	for i := 0; i <= len(p); i++ {
		if i < len(p) && p[i] != '/' {
			if !isPChar(p[i]) {
				return false
			}
			continue
		}
		comp := p[start:i]
		if comp == "" || len(comp) > 255 || comp == "." || comp == ".." {
			return false
		}
		start = i + 1
	}
	return true
}

// IsGenerated reports whether the first component of p is exactly "out".
func IsGenerated(p string) bool {
	return p == OutDir || strings.HasPrefix(p, OutDir+"/")
}

// globEligible reports whether p may be returned by glob.
func globEligible(p string) bool {
	return !IsGenerated(p) && p != StateFile
}

type file struct {
	content string
	hash    string // cached; empty when not yet computed
	stamp   int64  // modification stamp; never compared by the engine
}

// FS is an in-memory workspace. It is not safe for concurrent use.
type FS struct {
	files map[string]*file
	index []string // sorted glob-eligible paths
	clock int64
}

// New returns an empty workspace.
func New() *FS {
	return &FS{files: make(map[string]*file)}
}

// Has reports whether a file exists at path.
func (f *FS) Has(path string) bool {
	_, ok := f.files[path]
	return ok
}

// Read returns the content of the file at path.
func (f *FS) Read(path string) (string, bool) {
	e, ok := f.files[path]
	if !ok {
		return "", false
	}
	return e.content, true
}

// Hash returns the content hash of the file at path, computing it at most once
// per distinct content.
func (f *FS) Hash(path string) (string, bool) {
	e, ok := f.files[path]
	if !ok {
		return "", false
	}
	if e.hash == "" {
		e.hash = Hash(e.content)
	}
	return e.hash, true
}

// Write replaces the content of path, creating it if absent.
func (f *FS) Write(path, content string) {
	f.clock++
	if e, ok := f.files[path]; ok {
		e.content, e.hash, e.stamp = content, "", f.clock
		return
	}
	f.files[path] = &file{content: content, stamp: f.clock}
	if globEligible(path) {
		i := sort.SearchStrings(f.index, path)
		f.index = append(f.index, "")
		copy(f.index[i+1:], f.index[i:])
		f.index[i] = path
	}
}

// Delete removes the file at path, if any.
func (f *FS) Delete(path string) {
	if _, ok := f.files[path]; !ok {
		return
	}
	delete(f.files, path)
	if globEligible(path) {
		i := sort.SearchStrings(f.index, path)
		if i < len(f.index) && f.index[i] == path {
			f.index = append(f.index[:i], f.index[i+1:]...)
		}
	}
}

// Touch updates the modification stamp of path. Content is unaffected.
func (f *FS) Touch(path string) {
	if e, ok := f.files[path]; ok {
		f.clock++
		e.stamp = f.clock
	}
}

// Stamp returns the modification stamp of path.
func (f *FS) Stamp(path string) (int64, bool) {
	e, ok := f.files[path]
	if !ok {
		return 0, false
	}
	return e.stamp, true
}

// Len returns the number of files.
func (f *FS) Len() int { return len(f.files) }

// Paths returns every path in ascending byte order.
func (f *FS) Paths() []string {
	ps := make([]string, 0, len(f.files))
	for p := range f.files {
		ps = append(ps, p)
	}
	sort.Strings(ps)
	return ps
}

// Generated returns every generated path (first component "out") plus the
// state file, in ascending byte order. These are the paths `clean` removes.
func (f *FS) Generated() []string {
	var ps []string
	for p := range f.files {
		if IsGenerated(p) || p == StateFile {
			ps = append(ps, p)
		}
	}
	sort.Strings(ps)
	return ps
}

// GlobCandidates returns, in ascending order, the glob-eligible paths that
// start with prefix (not under out/, not the state file). It costs O(log F)
// plus the size of the result. The returned slice is freshly allocated.
func (f *FS) GlobCandidates(prefix string) []string {
	lo := sort.SearchStrings(f.index, prefix)
	hi := lo
	for hi < len(f.index) && strings.HasPrefix(f.index[hi], prefix) {
		hi++
	}
	return append([]string(nil), f.index[lo:hi]...)
}

// LoadDir reads every regular file below dir into a workspace. The top-level
// file named skipTop (if non-empty) is not loaded.
func LoadDir(dir, skipTop string) (*FS, error) {
	w := New()
	var paths, rels []string
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.Type().IsRegular() {
			return nil
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if rel == skipTop {
			return nil
		}
		paths = append(paths, p)
		rels = append(rels, rel)
		return nil
	})
	if err != nil {
		return nil, err
	}
	for i, p := range paths {
		b, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		w.Write(rels[i], string(b))
	}
	return w, nil
}

// WriteDir writes every file of the workspace to dir at its workspace path,
// creating intermediate directories as needed.
func (f *FS) WriteDir(dir string) error {
	for _, p := range f.Paths() {
		dst := filepath.Join(dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(dst, []byte(f.files[p].content), 0o644); err != nil {
			return err
		}
	}
	return nil
}
