package vfs

import (
	"io/fs"
	"os"
	"path/filepath"
)

// LoadDir reads every regular file under dir into the file system, keyed by
// its slash-separated path relative to dir. Files for which skip returns true
// are ignored; skip may be nil.
func (f *FS) LoadDir(dir string, skip func(rel string) bool) error {
	return filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.Type().IsRegular() {
			return nil
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if skip != nil && skip(rel) {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		f.Write(rel, data)
		return nil
	})
}

// WriteDir writes every file to dir at its workspace path, creating
// intermediate directories (each distinct directory only once).
func (f *FS) WriteDir(dir string) error {
	made := map[string]bool{}
	for _, p := range f.Paths() {
		full := filepath.Join(dir, filepath.FromSlash(p))
		parent := filepath.Dir(full)
		if !made[parent] {
			if err := os.MkdirAll(parent, 0o755); err != nil {
				return err
			}
			made[parent] = true
		}
		if err := os.WriteFile(full, f.files[p].content, 0o644); err != nil {
			return err
		}
	}
	return nil
}
