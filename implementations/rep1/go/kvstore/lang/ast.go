// Package lang implements the Tessera command language: a lexer and a
// recursive-descent parser that turn one command line into a Command.
package lang

import (
	"example.com/kvstore/query"
	"example.com/kvstore/value"
)

// Name identifies a command.
type Name string

// The fifteen commands.
const (
	Begin       Name = "begin"
	Commit      Name = "commit"
	Rollback    Name = "rollback"
	Checkpoint  Name = "checkpoint"
	Stat        Name = "stat"
	Indexes     Name = "indexes"
	Put         Name = "put"
	Get         Name = "get"
	Delete      Name = "delete"
	Update      Name = "update"
	Unset       Name = "unset"
	Scan        Name = "scan"
	Find        Name = "find"
	CreateIndex Name = "create index"
	DropIndex   Name = "drop index"
)

// ScanOptions are the options of a scan command.
type ScanOptions struct {
	From, To         []byte
	HasFrom, HasTo   bool
	Limit            int // -1 when absent
	Reverse, KeyOnly bool
}

// Command is a parsed command line. Which fields are meaningful depends on
// Name.
type Command struct {
	Name  Name
	Key   []byte      // put, get, delete, update, unset
	Path  value.Path  // update, unset, create index, drop index
	Value value.Value // put, update
	Pred  query.Node  // find
	Limit int         // find: -1 when absent
	Scan  ScanOptions // scan
}
