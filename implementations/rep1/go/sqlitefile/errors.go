package sqlitefile

import "errors"

var (
	// ErrNotDatabase is returned by Open when the data lacks the SQLite header
	// or declares an impossible page size.
	ErrNotDatabase = errors.New("sqlitefile: not a SQLite 3 database")
	// ErrCorrupt is returned when the file structure is inconsistent: a page
	// number or offset out of range, a truncated record, a B-tree cycle, etc.
	ErrCorrupt = errors.New("sqlitefile: database file is corrupt")
	// ErrQuery is returned for a query line that does not parse.
	ErrQuery = errors.New("sqlitefile: malformed query")
	// ErrNoSuchTable is returned when a query names a table that does not exist
	// (or is a view, index, trigger, or the schema table itself).
	ErrNoSuchTable = errors.New("sqlitefile: no such table")
	// ErrNoSuchColumn is returned when a query names an unknown column.
	ErrNoSuchColumn = errors.New("sqlitefile: no such column")
	// ErrNoSuchIndex is returned when an index lookup names something that is
	// not a usable single-column index created by CREATE INDEX.
	ErrNoSuchIndex = errors.New("sqlitefile: no such usable index")
)
