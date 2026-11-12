// Package mailbox turns an input path into a list of raw messages: either the
// messages of an mbox file or the .eml files of a directory.
package mailbox

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Source is one raw message and its source id.
type Source struct {
	// ID is "mbox:<n>" (1-based) for an mbox message or the file name for a
	// directory entry.
	ID string
	// Data is the message bytes.
	Data []byte
}

// Load reads the mailbox at path, which is a regular file (mbox) or a
// directory of .eml files.
func Load(path string) ([]Source, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.IsDir() {
		return LoadDir(path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	msgs := SplitMbox(data)
	out := make([]Source, len(msgs))
	for i, m := range msgs {
		out[i] = Source{ID: fmt.Sprintf("mbox:%d", i+1), Data: m}
	}
	return out, nil
}

// LoadDir reads every regular file directly inside dir whose name ends in
// ".eml", in ascending byte order of the names.
func LoadDir(dir string) ([]Source, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".eml") {
			continue
		}
		if fi, err := os.Stat(filepath.Join(dir, e.Name())); err != nil || !fi.Mode().IsRegular() {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names) // byte-wise comparison
	out := make([]Source, 0, len(names))
	for _, n := range names {
		data, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil {
			return nil, err
		}
		out = append(out, Source{ID: n, Data: data})
	}
	return out, nil
}

// SplitMbox splits an mbox archive into messages in one forward scan.
//
// A separator line starts with "From " and is the first line of the file or
// follows an empty line. Text before the first separator is discarded; a
// message ends where the next separator starts; a message ending in LF LF
// loses its final LF. The returned slices alias data.
func SplitMbox(data []byte) [][]byte {
	var msgs [][]byte
	prevEmpty := true // virtual empty line before the first line
	start := -1       // start of the current message body, -1 before the first separator
	var lineStart int
	for lineStart < len(data) {
		end := bytes.IndexByte(data[lineStart:], '\n')
		next := len(data)
		lineEnd := len(data)
		if end >= 0 {
			lineEnd = lineStart + end
			next = lineEnd + 1
		}
		line := data[lineStart:lineEnd]
		if prevEmpty && bytes.HasPrefix(line, []byte("From ")) {
			if start >= 0 {
				msgs = append(msgs, finish(data[start:lineStart]))
			}
			start = next
		}
		prevEmpty = len(line) == 0 || (len(line) == 1 && line[0] == '\r')
		lineStart = next
	}
	if start >= 0 {
		msgs = append(msgs, finish(data[start:]))
	}
	return msgs
}

func finish(m []byte) []byte {
	if bytes.HasSuffix(m, []byte("\n\n")) {
		return m[:len(m)-1]
	}
	return m
}
