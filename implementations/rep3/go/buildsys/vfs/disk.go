package vfs

import (
	"io/fs"
	"os"
	"path/filepath"
)

// Load walks the directory dir recursively and returns a file system holding
// every regular file, keyed by its slash-separated path relative to dir. The
// top-level file named skip (if non-empty) is left out.
func Load(dir, skip string) (*FS, error) {
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
		if skip != "" && rel == skip {
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

// WriteTo writes every file of f below dir, creating intermediate directories
// as needed (each distinct directory is created only once).
func (f *FS) WriteTo(dir string) error {
	made := map[string]bool{}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	made[dir] = true
	for _, p := range f.Paths() {
		full := filepath.Join(dir, filepath.FromSlash(p))
		if d := filepath.Dir(full); !made[d] {
			if err := os.MkdirAll(d, 0o755); err != nil {
				return err
			}
			made[d] = true
		}
		if err := os.WriteFile(full, f.files[p].content, 0o644); err != nil {
			return err
		}
	}
	return nil
}
