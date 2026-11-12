package sqlitefile

import (
	"errors"
	"fmt"
	"os"

	"sqlitefile/btree"
	"sqlitefile/schema"
)

// ErrUnsupported is returned for databases the reader cannot handle.
var ErrUnsupported = errors.New("sqlitefile: unsupported database")

// DB is an open, read-only SQLite database. The only state kept between
// queries is the file image and the parsed schema catalog. A DB is safe for
// concurrent use by multiple goroutines.
type DB struct {
	pager   *btree.Pager
	catalog *schema.Catalog
}

// Open reads the database file at path and its schema.
func Open(path string) (*DB, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return OpenBytes(data)
}

// OpenBytes opens a database from an in-memory image, which must not be
// modified afterwards.
func OpenBytes(data []byte) (*DB, error) {
	p, err := btree.NewPager(data)
	if err != nil {
		return nil, err
	}
	if enc := p.Encoding(); enc > 1 {
		return nil, fmt.Errorf("%w: text encoding %d (only UTF-8 is supported)", ErrUnsupported, enc)
	}
	cat, err := schema.Load(p)
	if err != nil {
		return nil, err
	}
	return &DB{pager: p, catalog: cat}, nil
}

// Catalog returns the parsed schema of the database.
func (db *DB) Catalog() *schema.Catalog { return db.catalog }
