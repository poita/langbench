// Package kvstore is Tessera, an embedded single-file transactional document
// store with a write-ahead log, a B+tree primary index, overflow pages for
// large values, secondary indexes on document fields, crash recovery and
// checkpointing, driven by a small command language.
//
// The package is a facade over the building blocks in its subpackages:
//
//	crc     CRC-32
//	value   the document value model (serialise, render, compare, paths)
//	lang    lexer and parser of the command language
//	query   predicate trees and their evaluation
//	engine  pager, B+tree, overflow pages, indexes, WAL, recovery
//
// A Store executes command lines and produces result blocks in the format of
// results.txt. Everything happens in memory on byte images of the database
// file and the log, so a Store is trivial to embed and to test:
//
//	s := kvstore.Open(nil, nil)
//	fmt.Print(s.Exec(`put "a" {name:"ada",age:36}`)) // [1] ok put created
//	fmt.Print(s.Exec(`get "a"`))
//	dbFile, walFile := s.Files()
package kvstore

import (
	"bytes"
	"strconv"

	"example.com/kvstore/engine"
	"example.com/kvstore/kverr"
	"example.com/kvstore/lang"
	"example.com/kvstore/value"
)

// Store executes Tessera commands against a database.
type Store struct {
	db   *engine.DB
	line int
	out  []byte
}

// Open opens a store on the given main-file and log images (either may be
// nil: a fresh database and an empty log). The log is recovered first: only
// committed transactions survive. The slices are not modified.
func Open(mainFile, walFile []byte) *Store {
	return &Store{db: engine.Open(mainFile, walFile)}
}

// DB returns the underlying storage engine.
func (s *Store) DB() *engine.DB { return s.db }

// Files returns the current main-file and log images. Call Close first to
// discard an open transaction.
func (s *Store) Files() (mainFile, walFile []byte) { return s.db.Images() }

// Close rolls back a transaction that is still open.
func (s *Store) Close() {
	if s.db.InTxn() {
		s.db.Rollback()
	}
}

// Exec runs one command line and returns its result block: a status line
// "[k] ..." followed by indented payload lines, every line ending in LF. The
// line counter k advances with every call.
func (s *Store) Exec(line string) string {
	s.line++
	s.out = s.out[:0]
	s.out = append(s.out, '[')
	s.out = strconv.AppendInt(s.out, int64(s.line), 10)
	s.out = append(s.out, "] "...)
	if err := s.run(line); err != nil {
		kind := kverr.KindOf(err)
		if kind == "" {
			kind = err.Error()
		}
		// Discard any payload written before the failure.
		s.out = append(s.out[:0], '[')
		s.out = strconv.AppendInt(s.out, int64(s.line), 10)
		s.out = append(s.out, "] error "...)
		s.out = append(s.out, kind...)
		s.out = append(s.out, '\n')
	}
	return string(s.out)
}

// SplitLines splits a command script into command lines: pieces separated by
// LF, where a final LF terminates the last line instead of starting another.
func SplitLines(script []byte) []string {
	if len(script) == 0 {
		return nil
	}
	if script[len(script)-1] == '\n' {
		script = script[:len(script)-1]
	}
	parts := bytes.Split(script, []byte{'\n'})
	lines := make([]string, len(parts))
	for i, p := range parts {
		lines[i] = string(p)
	}
	return lines
}

// RunScript opens a store on the given images, runs every line of script and
// returns the concatenated result blocks and the final main-file and log
// images. A transaction left open at the end is rolled back.
func RunScript(script, mainFile, walFile []byte) (results, mainOut, walOut []byte) {
	s := Open(mainFile, walFile)
	var buf bytes.Buffer
	for _, l := range SplitLines(script) {
		buf.WriteString(s.Exec(l))
	}
	s.Close()
	mainOut, walOut = s.Files()
	return buf.Bytes(), mainOut, walOut
}

// status appends a status line made of the given pieces after the "[k] " prefix.
func (s *Store) status(parts ...any) {
	for _, p := range parts {
		switch v := p.(type) {
		case string:
			s.out = append(s.out, v...)
		case int:
			s.out = strconv.AppendInt(s.out, int64(v), 10)
		case uint64:
			s.out = strconv.AppendUint(s.out, v, 10)
		case uint32:
			s.out = strconv.AppendUint(s.out, uint64(v), 10)
		}
	}
	s.out = append(s.out, '\n')
}

// payload appends an indented payload line made of the given pieces.
func (s *Store) payload(parts ...any) {
	s.out = append(s.out, ' ', ' ')
	for _, p := range parts {
		switch v := p.(type) {
		case string:
			s.out = append(s.out, v...)
		case int:
			s.out = strconv.AppendInt(s.out, int64(v), 10)
		case uint64:
			s.out = strconv.AppendUint(s.out, v, 10)
		case uint32:
			s.out = strconv.AppendUint(s.out, uint64(v), 10)
		}
	}
	s.out = append(s.out, '\n')
}

func (s *Store) run(line string) error {
	cmd, err := lang.Parse(line)
	if err != nil {
		return err
	}
	db := s.db
	switch cmd.Name {
	case lang.Begin:
		if err := db.Begin(); err != nil {
			return err
		}
		s.status("ok begin")
	case lang.Commit:
		txn, frames, err := db.Commit()
		if err != nil {
			return err
		}
		s.status("ok commit ", txn, " frames ", frames)
	case lang.Rollback:
		if err := db.Rollback(); err != nil {
			return err
		}
		s.status("ok rollback")
	case lang.Checkpoint:
		n, err := db.Checkpoint()
		if err != nil {
			return err
		}
		s.status("ok checkpoint pages ", n)
	case lang.Put:
		created, err := db.Put(cmd.Key, cmd.Value)
		if err != nil {
			return err
		}
		if created {
			s.status("ok put created")
		} else {
			s.status("ok put replaced")
		}
	case lang.Get:
		doc, err := db.Get(cmd.Key)
		if err != nil {
			return err
		}
		s.status("ok get value")
		s.out = append(s.out, ' ', ' ')
		s.out = value.AppendRender(s.out, doc)
		s.out = append(s.out, '\n')
	case lang.Delete:
		if err := db.Delete(cmd.Key); err != nil {
			return err
		}
		s.status("ok delete removed")
	case lang.Update:
		if err := db.Update(cmd.Key, cmd.Path, cmd.Value); err != nil {
			return err
		}
		s.status("ok update updated")
	case lang.Unset:
		if err := db.Unset(cmd.Key, cmd.Path); err != nil {
			return err
		}
		s.status("ok unset updated")
	case lang.Scan:
		o := cmd.Scan
		entries := db.Scan(engine.ScanOptions{
			From: o.From, To: o.To, HasFrom: o.HasFrom, HasTo: o.HasTo,
			Limit: o.Limit, Reverse: o.Reverse, KeysOnly: o.KeyOnly,
		})
		s.status("ok scan ", len(entries))
		s.entries(entries, o.KeyOnly)
	case lang.Find:
		entries, plan := db.Find(cmd.Pred, cmd.Limit)
		s.status("ok find ", len(entries), " plan ", plan)
		s.entries(entries, false)
	case lang.CreateIndex:
		n, err := db.CreateIndex(cmd.Path)
		if err != nil {
			return err
		}
		s.status("ok create index ", cmd.Path.String(), " entries ", n)
	case lang.DropIndex:
		n, err := db.DropIndex(cmd.Path)
		if err != nil {
			return err
		}
		s.status("ok drop index ", cmd.Path.String(), " pages ", n)
	case lang.Indexes:
		infos := db.Indexes()
		s.status("ok indexes ", len(infos))
		for _, i := range infos {
			s.payload(i.Slot, " ", i.Path, " root ", i.Root, " entries ", i.Entries)
		}
	case lang.Stat:
		st := db.Stat()
		s.status("ok stat")
		s.payload("pages ", st.Pages)
		s.payload("free ", st.Free)
		s.payload("freehead ", st.FreeHead)
		s.payload("docs ", st.Docs)
		s.payload("root ", st.Root)
		s.payload("height ", st.Height)
		s.payload("commits ", st.Commits)
		s.payload("indexes ", st.Indexes)
		s.payload("wal ", st.WAL)
	}
	return nil
}

func (s *Store) entries(entries []engine.Entry, keysOnly bool) {
	for _, e := range entries {
		s.out = append(s.out, ' ', ' ')
		s.out = value.AppendQuoted(s.out, string(e.Key))
		if !keysOnly {
			s.out = append(s.out, " = "...)
			s.out = value.AppendRender(s.out, e.Doc)
		}
		s.out = append(s.out, '\n')
	}
}
