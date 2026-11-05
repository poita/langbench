// Package vfs implements Kiln's in-memory virtual file system.
//
// The workspace is a flat map from workspace paths to immutable byte
// contents. Every file caches its FNV-1a hash, which stays valid until the file
// is replaced, and the package maintains a sorted index of the paths that
// `glob` may return so that prefix lookups are logarithmic.
package vfs

import "sort"

type file struct {
	content []byte
	hash    uint64
	hashed  bool
	stamp   uint64
}

// FS is a virtual file system. The zero value is not usable; call New.
// An FS is not safe for concurrent use.
type FS struct {
	files map[string]*file
	index []string // sorted glob-eligible paths
	dirty bool     // index needs rebuilding
	clock uint64
}

// New returns an empty file system.
func New() *FS { return &FS{files: make(map[string]*file)} }

// Len returns the number of files.
func (f *FS) Len() int { return len(f.files) }

// Exists reports whether a file exists at path p.
func (f *FS) Exists(p string) bool { _, ok := f.files[p]; return ok }

// Read returns the content of p. The returned slice is shared with the file
// system and must not be modified.
func (f *FS) Read(p string) ([]byte, bool) {
	fl, ok := f.files[p]
	if !ok {
		return nil, false
	}
	return fl.content, true
}

// Write replaces the content of p, creating the file if it is absent. The
// file system takes ownership of content, which must not be modified later.
func (f *FS) Write(p string, content []byte) {
	f.clock++
	if fl, ok := f.files[p]; ok {
		fl.content, fl.hashed, fl.stamp = content, false, f.clock
		return
	}
	f.files[p] = &file{content: content, stamp: f.clock}
	if GlobEligible(p) {
		f.dirty = true
	}
}

// Delete removes p and reports whether it existed.
func (f *FS) Delete(p string) bool {
	if _, ok := f.files[p]; !ok {
		return false
	}
	delete(f.files, p)
	if GlobEligible(p) {
		f.dirty = true
	}
	return true
}

// Touch updates the modification stamp of p and nothing else.
func (f *FS) Touch(p string) {
	if fl, ok := f.files[p]; ok {
		f.clock++
		fl.stamp = f.clock
	}
}

// Stamp returns the modification stamp of p (0 if it does not exist). Stamps
// increase monotonically with every write or touch.
func (f *FS) Stamp(p string) uint64 {
	if fl, ok := f.files[p]; ok {
		return fl.stamp
	}
	return 0
}

// Hash returns the FNV-1a hash of the content of p, computing it at most once
// per distinct content.
func (f *FS) Hash(p string) (uint64, bool) {
	fl, ok := f.files[p]
	if !ok {
		return 0, false
	}
	if !fl.hashed {
		fl.hash, fl.hashed = Hash64(fl.content), true
	}
	return fl.hash, true
}

// Paths returns every path in the file system in ascending byte order.
func (f *FS) Paths() []string {
	out := make([]string, 0, len(f.files))
	for p := range f.files {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

func (f *FS) ensureIndex() {
	if !f.dirty && f.index != nil {
		return
	}
	idx := make([]string, 0, len(f.files))
	for p := range f.files {
		if GlobEligible(p) {
			idx = append(idx, p)
		}
	}
	sort.Strings(idx)
	f.index, f.dirty = idx, false
}

// Candidates returns, in ascending order, every glob-eligible path that starts
// with prefix. The returned slice aliases the index and must not be modified.
func (f *FS) Candidates(prefix string) []string {
	f.ensureIndex()
	idx := f.index
	lo := sort.SearchStrings(idx, prefix)
	hi := lo + sort.Search(len(idx)-lo, func(i int) bool {
		s := idx[lo+i]
		return len(s) < len(prefix) || s[:len(prefix)] != prefix
	})
	return idx[lo:hi]
}
