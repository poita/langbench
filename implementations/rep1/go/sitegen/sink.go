package sitegen

import (
	"os"
	"path/filepath"
)

// A Sink receives the generated files. Names are slash-separated paths
// relative to the output root, such as "posts/hello/index.html".
type Sink interface {
	WriteFile(name string, data []byte) error
}

// DirSink returns a Sink that writes files below dir, creating directories
// as needed.
func DirSink(dir string) Sink { return dirSink(dir) }

type dirSink string

func (d dirSink) WriteFile(name string, data []byte) error {
	path := filepath.Join(string(d), filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// MemSink is an in-memory Sink that maps file names to contents. It is
// convenient in tests.
type MemSink map[string][]byte

// WriteFile stores a copy of data under name.
func (m MemSink) WriteFile(name string, data []byte) error {
	m[name] = append([]byte(nil), data...)
	return nil
}
