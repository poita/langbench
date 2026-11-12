// Package tessera is an embedded, single-file transactional document store.
//
// A database consists of a main file of 1024-byte pages (a header page, a
// B+tree primary index keyed by document key, overflow pages for large
// documents, secondary indexes on document fields and a free list) and a
// write-ahead log. Committed changes live in the log until a checkpoint copies
// them into the main file; opening a database replays the committed part of
// the log. Every byte of both files is determined by the sequence of commands
// applied, so two runs of the same script produce identical files.
//
// The package works on in-memory images of the two files: Open takes their
// contents, DatabaseFile and LogFile return them, and the command-line tool in
// cmd/tessera reads and writes them.
//
// There are two ways to drive a database. The typed API (Put, Get, Delete,
// Update, Unset, Scan, Find, CreateIndex, DropIndex, Begin, Commit, Rollback,
// Checkpoint, Stat) takes and returns value.Value documents. The command
// language (Exec, ParseCommand, RunScript) accepts the textual commands
// documented in the README and produces the text of results.txt.
//
// Every failure is an *Error whose Kind names the reason; a failed operation
// leaves the database untouched. A DB is not safe for concurrent use.
package tessera
