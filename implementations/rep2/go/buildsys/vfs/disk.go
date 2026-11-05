package vfs

import (
	"io/fs"
	"os"
	"path/filepath"
)

// LoadDir reads every regular file below dir into a new FS. Paths are
// relative to dir and use "/" separators. A top-level file named skipTop (if
// non-empty) is ignored.
func LoadDir(dir, skipTop string) (*FS, error) {
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
		if skipTop != "" && rel == skipTop {
			return nil
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		v.Write(rel, data)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return v, nil
}

// WriteDir writes every file of the FS below dir, creating each distinct
// parent directory once.
func (fs *FS) WriteDir(dir string) error {
	made := map[string]bool{}
	for _, p := range fs.Paths() {
		full := filepath.Join(dir, filepath.FromSlash(p))
		parent := filepath.Dir(full)
		if !made[parent] {
			if err := os.MkdirAll(parent, 0o755); err != nil {
				return err
			}
			made[parent] = true
		}
		if err := os.WriteFile(full, fs.files[p].Data, 0o644); err != nil {
			return err
		}
	}
	return nil
}
