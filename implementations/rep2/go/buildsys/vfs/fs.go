// Package vfs implements Kiln's in-memory virtual file system: a flat map
// from workspace paths to immutable file contents with cached FNV-1a hashes,
// plus a sorted index used to answer glob queries by literal prefix.
package vfs

import (
	"sort"
	"strings"
)

// File is one workspace file. Its content is never modified in place;
// writing a path replaces the whole record, so content slices can be shared.
type File struct {
	Data  []byte
	Stamp int64 // modification stamp; never consulted by the build engine
	hash  uint64
	valid bool
}

// FS is a virtual file system. The zero value is not usable; call New.
type FS struct {
	files map[string]*File
	clock int64

	index      []string // sorted glob-eligible paths
	indexDirty bool
}

// New returns an empty file system.
func New() *FS {
	return &FS{files: make(map[string]*File)}
}

// Len returns the number of files.
func (fs *FS) Len() int { return len(fs.files) }

// Exists reports whether a file exists at path.
func (fs *FS) Exists(path string) bool {
	_, ok := fs.files[path]
	return ok
}

// Read returns the content of the file at path. The returned slice is shared
// and must not be modified.
func (fs *FS) Read(path string) ([]byte, bool) {
	f, ok := fs.files[path]
	if !ok {
		return nil, false
	}
	return f.Data, true
}

// Lookup returns the content and the (cached) hash of the file at path.
func (fs *FS) Lookup(path string) (data []byte, hash uint64, ok bool) {
	f, ok := fs.files[path]
	if !ok {
		return nil, 0, false
	}
	if !f.valid {
		f.hash = Hash(f.Data)
		f.valid = true
	}
	return f.Data, f.hash, true
}

// Hash returns the content hash of the file at path.
func (fs *FS) Hash(path string) (uint64, bool) {
	_, h, ok := fs.Lookup(path)
	return h, ok
}

func (fs *FS) put(path string, f *File) {
	fs.clock++
	f.Stamp = fs.clock
	if _, existed := fs.files[path]; !existed && GlobEligible(path) {
		fs.indexDirty = true
	}
	fs.files[path] = f
}

// Write creates or replaces the file at path. The hash is computed lazily.
// The FS takes ownership of data.
func (fs *FS) Write(path string, data []byte) {
	fs.put(path, &File{Data: data})
}

// WriteHashed is like Write but supplies the already-known hash of data.
func (fs *FS) WriteHashed(path string, data []byte, hash uint64) {
	fs.put(path, &File{Data: data, hash: hash, valid: true})
}

// Delete removes the file at path, reporting whether it existed.
func (fs *FS) Delete(path string) bool {
	if _, ok := fs.files[path]; !ok {
		return false
	}
	delete(fs.files, path)
	if GlobEligible(path) {
		fs.indexDirty = true
	}
	return true
}

// Touch updates the modification stamp of path. Content and hash are
// untouched.
func (fs *FS) Touch(path string) {
	if f, ok := fs.files[path]; ok {
		fs.clock++
		f.Stamp = fs.clock
	}
}

// Paths returns every path in ascending byte order.
func (fs *FS) Paths() []string {
	out := make([]string, 0, len(fs.files))
	for p := range fs.files {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// Generated returns the paths of the reserved "out" tree plus the state
// file, if present, in ascending order. This is exactly the set removed by a
// session "clean".
func (fs *FS) Generated() []string {
	var out []string
	for p := range fs.files {
		if IsGenerated(p) || p == StatePath {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

func (fs *FS) buildIndex() {
	if !fs.indexDirty && fs.index != nil {
		return
	}
	fs.index = fs.index[:0]
	for p := range fs.files {
		if GlobEligible(p) {
			fs.index = append(fs.index, p)
		}
	}
	sort.Strings(fs.index)
	if fs.index == nil {
		fs.index = []string{}
	}
	fs.indexDirty = false
}

// GlobCandidates returns the sorted glob-eligible paths that start with the
// byte prefix. The result aliases an internal index and must not be
// modified or retained across mutations of the file system.
func (fs *FS) GlobCandidates(prefix string) []string {
	fs.buildIndex()
	idx := fs.index
	lo := sort.Search(len(idx), func(i int) bool { return idx[i] >= prefix })
	hi := lo
	for hi < len(idx) && strings.HasPrefix(idx[hi], prefix) {
		hi++
	}
	return idx[lo:hi]
}
