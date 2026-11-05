// Package mailbox enumerates the messages of an mbox file or of a directory
// of .eml files.
package mailbox

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"mimedump/lines"
)

// Mailbox is an ordered collection of raw messages. Directory messages are
// read lazily, one file at a time.
type Mailbox struct {
	ids   []string
	data  [][]byte // mbox: slices of the file; directory: nil
	paths []string // directory: file paths; mbox: nil
}

// Open opens path, which is either an mbox file or a directory.
func Open(path string) (*Mailbox, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if st.IsDir() {
		return openDir(path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return FromMbox(data), nil
}

func openDir(dir string) (*Mailbox, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".eml") {
			continue
		}
		st, err := os.Stat(filepath.Join(dir, e.Name()))
		if err != nil || !st.Mode().IsRegular() {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names) // byte-wise order
	m := &Mailbox{ids: names}
	for _, n := range names {
		m.paths = append(m.paths, filepath.Join(dir, n))
	}
	return m, nil
}

// FromMbox splits mbox file contents into messages with source ids
// "mbox:1", "mbox:2", ... The messages alias data.
//
// A separator line starts with "From " and is the first line or follows an
// empty line. Text before the first separator is discarded. A message runs
// to the next separator; if it ends in LF LF the final LF is dropped.
func FromMbox(data []byte) *Mailbox {
	m := &Mailbox{}
	cur := -1
	prevEmpty := true // the first line counts as following an empty line
	finish := func(end int) {
		if cur < 0 {
			return
		}
		msg := data[cur:end]
		if n := len(msg); n >= 2 && msg[n-1] == '\n' && msg[n-2] == '\n' {
			msg = msg[:n-1]
		}
		m.data = append(m.data, msg)
		m.ids = append(m.ids, fmt.Sprintf("mbox:%d", len(m.ids)+1))
	}
	for pos := 0; pos < len(data); {
		line, size, _ := lines.Next(data[pos:])
		if prevEmpty && bytes.HasPrefix(line, []byte("From ")) {
			finish(pos)
			cur = pos + size
		}
		prevEmpty = len(line) == 0
		pos += size
	}
	finish(len(data))
	return m
}

// Len returns the number of messages.
func (m *Mailbox) Len() int { return len(m.ids) }

// SourceID returns the source id of message i (0-based): the file name for a
// directory, "mbox:N" (1-based) for an mbox.
func (m *Mailbox) SourceID(i int) string { return m.ids[i] }

// Message returns the raw bytes of message i (0-based).
func (m *Mailbox) Message(i int) ([]byte, error) {
	if m.paths != nil {
		return os.ReadFile(m.paths[i])
	}
	return m.data[i], nil
}
