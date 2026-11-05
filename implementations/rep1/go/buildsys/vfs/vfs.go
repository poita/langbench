// Package vfs implements the in-memory virtual file system that a Kiln
// session runs against: a flat map from workspace paths to immutable byte
// contents, with cached content hashes and a sorted index for glob lookups.
package vfs

import (
	"sort"
	"strings"
)

type file struct {
	content []byte
	hash    uint64
	hashOK  bool
	stamp   uint64
}

// FS is a virtual file system. The zero value is not usable; call New.
// An FS is not safe for concurrent use.
type FS struct {
	files      map[string]*file
	index      []string // sorted glob-eligible paths
	indexDirty bool
	clock      uint64
}

// New returns an empty file system.
func New() *FS {
	return &FS{files: make(map[string]*file)}
}

// Len returns the number of files.
func (fs *FS) Len() int { return len(fs.files) }

// Exists reports whether a file exists at p.
func (fs *FS) Exists(p string) bool {
	_, ok := fs.files[p]
	return ok
}

// Read returns the content of p. The returned slice is shared with the file
// system and must not be modified.
func (fs *FS) Read(p string) ([]byte, bool) {
	f, ok := fs.files[p]
	if !ok {
		return nil, false
	}
	return f.content, true
}

// Write replaces (or creates) the file at p. The slice is retained, not
// copied, and must not be modified afterwards. The content hash is computed
// lazily on first use.
func (fs *FS) Write(p string, content []byte) {
	fs.put(p, content, 0, false)
}

// WriteHashed is like Write but supplies the already-computed hash of content.
func (fs *FS) WriteHashed(p string, content []byte, hash uint64) {
	fs.put(p, content, hash, true)
}

func (fs *FS) put(p string, content []byte, hash uint64, ok bool) {
	fs.clock++
	if f, exists := fs.files[p]; exists {
		f.content, f.hash, f.hashOK, f.stamp = content, hash, ok, fs.clock
		return
	}
	fs.files[p] = &file{content: content, hash: hash, hashOK: ok, stamp: fs.clock}
	if GlobEligible(p) {
		fs.indexDirty = true
	}
}

// Delete removes the file at p and reports whether it existed.
func (fs *FS) Delete(p string) bool {
	if _, ok := fs.files[p]; !ok {
		return false
	}
	delete(fs.files, p)
	if GlobEligible(p) {
		fs.indexDirty = true
	}
	return true
}

// Touch updates the modification stamp of p. Nothing in Kiln ever compares
// stamps; the call exists to model the session's touch step.
func (fs *FS) Touch(p string) {
	if f, ok := fs.files[p]; ok {
		fs.clock++
		f.stamp = fs.clock
	}
}

// Stamp returns the modification stamp of p (larger means more recent).
func (fs *FS) Stamp(p string) (uint64, bool) {
	f, ok := fs.files[p]
	if !ok {
		return 0, false
	}
	return f.stamp, true
}

// Hash returns the FNV-1a hash of the content of p, computing and caching it
// on first use. The cached value stays valid until the file is rewritten.
func (fs *FS) Hash(p string) (uint64, bool) {
	f, ok := fs.files[p]
	if !ok {
		return 0, false
	}
	if !f.hashOK {
		f.hash, f.hashOK = Hash64(f.content), true
	}
	return f.hash, true
}

// Paths returns every path in the file system in ascending byte order.
func (fs *FS) Paths() []string {
	out := make([]string, 0, len(fs.files))
	for p := range fs.files {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// Candidates returns the sorted glob-eligible paths that begin with the byte
// prefix. The result aliases an internal index and must not be modified or
// retained across mutations. The index is rebuilt lazily, at most once per
// change of the eligible path set.
func (fs *FS) Candidates(prefix string) []string {
	if fs.indexDirty || fs.index == nil {
		fs.index = fs.index[:0]
		for p := range fs.files {
			if GlobEligible(p) {
				fs.index = append(fs.index, p)
			}
		}
		sort.Strings(fs.index)
		fs.indexDirty = false
	}
	lo := sort.SearchStrings(fs.index, prefix)
	hi := lo
	for hi < len(fs.index) && strings.HasPrefix(fs.index[hi], prefix) {
		hi++
	}
	return fs.index[lo:hi]
}
