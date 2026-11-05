package sqlitefile

import (
	"fmt"
	"sort"
	"strings"
)

// SchemaEntry is one row of the sqlite_schema table.
type SchemaEntry struct {
	Type    string // "table", "index", "view", "trigger"
	Name    string
	TblName string
	Root    int64 // 0 for objects without a B-tree
	SQL     string
	HasSQL  bool // false when the sql column is NULL
}

// DB is an open, read-only SQLite database image held in memory. After Open it
// is immutable, so a DB may be shared between goroutines.
type DB struct {
	pager   *pager
	entries []SchemaEntry
	tables  map[string]*Table // keyed by ASCII-lower-cased name
	indexes map[string]*Index
}

// Open reads the database file at path and loads its schema.
func Open(path string) (*DB, error) {
	data, err := readFile(path)
	if err != nil {
		return nil, err
	}
	return OpenBytes(data)
}

// OpenBytes opens a database image already in memory. The slice is used
// directly (not copied) and must not be modified afterwards.
func OpenBytes(data []byte) (db *DB, err error) {
	defer recoverCorrupt(&err)
	p, err := newPager(data)
	if err != nil {
		return nil, err
	}
	db = &DB{pager: p, tables: map[string]*Table{}, indexes: map[string]*Index{}}
	if err := db.loadSchema(); err != nil {
		return nil, err
	}
	return db, nil
}

// recoverCorrupt converts a runtime panic caused by a malformed file (an
// out-of-range slice, say) into ErrCorrupt.
func recoverCorrupt(err *error) {
	if rec := recover(); rec != nil {
		if _, ok := rec.(interface{ RuntimeError() }); ok {
			*err = ErrCorrupt
			return
		}
		panic(rec)
	}
}

func (db *DB) loadSchema() error {
	r := &reader{pg: db.pager}
	var rec record
	err := r.walkTable(1, func(rowid int64, payload []byte, _ bool) (bool, error) {
		if err := rec.parse(payload); err != nil {
			return false, err
		}
		e := SchemaEntry{
			Type:    string(rec.value(0).B),
			Name:    string(rec.value(1).B),
			TblName: string(rec.value(2).B),
			Root:    rec.value(3).I,
		}
		if sv := rec.value(4); sv.Kind == KindText {
			e.SQL, e.HasSQL = string(sv.B), true
		}
		db.entries = append(db.entries, e)
		return false, nil
	})
	if err != nil {
		return err
	}
	for _, e := range db.entries {
		key := asciiLower(e.Name)
		switch e.Type {
		case "table":
			t := &Table{Name: e.Name, Root: uint32(e.Root), SQL: e.SQL, RowidAlias: -1}
			if !e.HasSQL || e.Root <= 0 {
				t.err = errDDL
			} else if parsed, perr := ParseCreateTable(e.SQL); perr != nil {
				t.err = perr
			} else {
				parsed.Name, parsed.Root, parsed.SQL = e.Name, uint32(e.Root), e.SQL
				t = parsed
			}
			if _, dup := db.tables[key]; !dup {
				db.tables[key] = t
			}
		case "index":
			if !e.HasSQL || e.Root <= 0 {
				continue
			}
			ix, perr := ParseCreateIndex(e.SQL)
			if perr != nil {
				continue
			}
			ix.Name, ix.Root, ix.SQL = e.Name, uint32(e.Root), e.SQL
			if t := e.TblName; t != "" {
				ix.Table = t
			}
			if _, dup := db.indexes[key]; !dup {
				db.indexes[key] = ix
			}
		}
	}
	return nil
}

func asciiLower(s string) string {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= 'A' && c <= 'Z' {
			b := []byte(s)
			for j := i; j < len(b); j++ {
				if b[j] >= 'A' && b[j] <= 'Z' {
					b[j] += 32
				}
			}
			return string(b)
		}
	}
	return s
}

// Entries returns the rows of sqlite_schema in schema (rowid) order.
func (db *DB) Entries() []SchemaEntry { return db.entries }

// Tables lists the user tables: schema rows of type "table" whose names do not
// start with "sqlite_", sorted by the byte order of the name.
func (db *DB) Tables() []string {
	var names []string
	for _, e := range db.entries {
		if e.Type == "table" && !strings.HasPrefix(asciiLower(e.Name), "sqlite_") {
			names = append(names, e.Name)
		}
	}
	sort.Strings(names)
	return names
}

// Schema returns, in schema order, the SQL text of every schema row belonging
// to the named table (ASCII case-insensitive match on tbl_name): the CREATE
// TABLE plus its indexes and triggers. Rows with a NULL sql are skipped.
func (db *DB) Schema(table string) []string {
	var out []string
	want := asciiLower(table)
	for _, e := range db.entries {
		if e.HasSQL && asciiLower(e.TblName) == want {
			out = append(out, e.SQL)
		}
	}
	return out
}

// Table looks up a table by name (ASCII case-insensitive).
func (db *DB) Table(name string) (*Table, error) {
	t, ok := db.tables[asciiLower(name)]
	if !ok || t.err != nil {
		return nil, fmt.Errorf("%w: %s", ErrNoSuchTable, name)
	}
	return t, nil
}

// Index looks up an explicitly created index by name (ASCII case-insensitive).
func (db *DB) Index(name string) (*Index, bool) {
	ix, ok := db.indexes[asciiLower(name)]
	return ix, ok
}

// Count returns the number of rows in a table without reading any payloads.
func (db *DB) Count(table string) (n int64, err error) {
	defer recoverCorrupt(&err)
	t, err := db.Table(table)
	if err != nil {
		return 0, err
	}
	r := &reader{pg: db.pager}
	return r.countTable(t.Root, 0)
}
