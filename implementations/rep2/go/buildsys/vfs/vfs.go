// Package vfs implements the virtual file system a Kiln session runs against:
// a flat map from workspace paths to file contents, with cached FNV-1a content
// hashes and a sorted index of the paths that glob may match.
package vfs

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// StateFile is the workspace path in which Kiln persists build state.
const StateFile = ".kiln-state"

// OutDir is the first component of every generated path.
const OutDir = "out"

// File is an immutable snapshot of a file's content. Writing to a path
// replaces its File, so a *File obtained earlier keeps describing the content
// that was current when it was obtained.
type File struct {
	content string
	hash    uint64
	hashed  bool
}

// Content returns the file's bytes.
func (f *File) Content() string { return f.content }

// Hash returns the FNV-1a 64-bit hash of the content. It is computed on first
// use and then cached for the lifetime of this File.
func (f *File) Hash() uint64 {
	if !f.hashed {
		f.hash = Hash(f.content)
		f.hashed = true
	}
	return f.hash
}

// FS is a virtual file system. The zero value is not usable; call New.
type FS struct {
	files map[string]*File
	stamp map[string]uint64
	clock uint64
	// index holds, sorted, every path that glob may match.
	index []string
}

// New returns an empty file system.
func New() *FS {
	return &FS{files: map[string]*File{}, stamp: map[string]uint64{}}
}

// Get returns the file at path, or nil if there is none.
func (v *FS) Get(path string) *File { return v.files[path] }

// Exists reports whether a file exists at path.
func (v *FS) Exists(path string) bool { _, ok := v.files[path]; return ok }

// Len returns the number of files.
func (v *FS) Len() int { return len(v.files) }

// Write creates or replaces the file at path.
func (v *FS) Write(path, content string) {
	if _, ok := v.files[path]; !ok && Globbable(path) {
		i := sort.SearchStrings(v.index, path)
		v.index = append(v.index, "")
		copy(v.index[i+1:], v.index[i:])
		v.index[i] = path
	}
	v.files[path] = &File{content: content}
	v.clock++
	v.stamp[path] = v.clock
}

// Delete removes the file at path, if any.
func (v *FS) Delete(path string) {
	if _, ok := v.files[path]; !ok {
		return
	}
	delete(v.files, path)
	delete(v.stamp, path)
	if Globbable(path) {
		i := sort.SearchStrings(v.index, path)
		if i < len(v.index) && v.index[i] == path {
			v.index = append(v.index[:i], v.index[i+1:]...)
		}
	}
}

// Touch updates the modification stamp of path. Kiln never reads stamps; they
// exist only so that touch is a real operation.
func (v *FS) Touch(path string) {
	if _, ok := v.files[path]; ok {
		v.clock++
		v.stamp[path] = v.clock
	}
}

// Stamp returns the modification stamp of path (0 if it does not exist).
func (v *FS) Stamp(path string) uint64 { return v.stamp[path] }

// Paths returns every path in the file system, sorted.
func (v *FS) Paths() []string {
	out := make([]string, 0, len(v.files))
	for p := range v.files {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// WithPrefix returns, in sorted order, every glob-eligible path that begins
// with prefix. It costs O(log F) plus the size of the result. The returned
// slice aliases the index and is valid only until the next Write or Delete.
func (v *FS) WithPrefix(prefix string) []string {
	i := sort.SearchStrings(v.index, prefix)
	j := i
	for j < len(v.index) && strings.HasPrefix(v.index[j], prefix) {
		j++
	}
	return v.index[i:j]
}

// Clean deletes every generated path and the state file and returns the
// removed paths in ascending order.
func (v *FS) Clean() []string {
	var removed []string
	for p := range v.files {
		if IsGenerated(p) || p == StateFile {
			removed = append(removed, p)
		}
	}
	sort.Strings(removed)
	for _, p := range removed {
		v.Delete(p)
	}
	return removed
}

// IsGenerated reports whether the first component of path is exactly "out".
func IsGenerated(path string) bool {
	return path == OutDir || strings.HasPrefix(path, OutDir+"/")
}

// Globbable reports whether glob may match path.
func Globbable(path string) bool {
	return !IsGenerated(path) && path != StateFile
}

// ValidPath reports whether s is a workspace path.
func ValidPath(s string) bool {
	if len(s) == 0 || len(s) > 1024 {
		return false
	}
	start := 0
	for i := 0; i <= len(s); i++ {
		if i < len(s) && s[i] != '/' {
			if !pchar(s[i]) {
				return false
			}
			continue
		}
		comp := s[start:i]
		if len(comp) == 0 || len(comp) > 255 || comp == "." || comp == ".." {
			return false
		}
		start = i + 1
	}
	return true
}

func pchar(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' ||
		c == '_' || c == '.' || c == '+' || c == '-'
}

// Hash computes the 64-bit FNV-1a hash of s.
func Hash(s string) uint64 {
	h := uint64(0xcbf29ce484222325)
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 0x100000001b3
	}
	return h
}

// HashString formats a hash as 16 lowercase hexadecimal digits.
func HashString(h uint64) string {
	const digits = "0123456789abcdef"
	var b [16]byte
	for i := 15; i >= 0; i-- {
		b[i] = digits[h&0xf]
		h >>= 4
	}
	return string(b[:])
}

// ParseHash parses exactly 16 lowercase hexadecimal digits.
func ParseHash(s string) (uint64, bool) {
	if len(s) != 16 {
		return 0, false
	}
	var h uint64
	for i := 0; i < 16; i++ {
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
			h = h<<4 | uint64(c-'0')
		case c >= 'a' && c <= 'f':
			h = h<<4 | uint64(c-'a'+10)
		default:
			return 0, false
		}
	}
	return h, true
}

// Load reads every regular file under dir into a new FS. Paths use "/" as the
// separator and are relative to dir. Files for which skip returns true are
// left out; skip may be nil.
func Load(dir string, skip func(rel string) bool) (*FS, error) {
	v := New()
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
		if skip != nil && skip(rel) {
			return nil
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		v.files[rel] = &File{content: string(data)}
		if Globbable(rel) {
			v.index = append(v.index, rel)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(v.index)
	return v, nil
}

// Export writes every file into dir at its workspace path, creating
// intermediate directories as needed.
func (v *FS) Export(dir string) error {
	for _, p := range v.Paths() {
		full := filepath.Join(dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(full, []byte(v.files[p].content), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// NewFile returns a standalone File snapshot holding content.
func NewFile(content string) *File { return &File{content: content} }
