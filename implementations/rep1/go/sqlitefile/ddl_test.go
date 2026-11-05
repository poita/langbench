package sqlitefile

import (
	"reflect"
	"testing"
)

func TestParseCreateTableAlias(t *testing.T) {
	cases := []struct {
		sql   string
		alias int
	}{
		{"CREATE TABLE t(id INTEGER PRIMARY KEY, x)", 0},
		{"CREATE TABLE t(x, id integer primary key autoincrement)", 1},
		{"CREATE TABLE t(id INTEGER PRIMARY KEY ASC)", 0},
		{"CREATE TABLE t(id INTEGER PRIMARY KEY DESC)", -1},
		{"CREATE TABLE t(id INTEGER, PRIMARY KEY(id DESC))", 0},
		{"CREATE TABLE t(id INTEGER, PRIMARY KEY(id))", 0},
		{"CREATE TABLE t([AlbumId] INTEGER NOT NULL, CONSTRAINT [PK_Album] PRIMARY KEY ([AlbumId]))", 0},
		{"CREATE TABLE t(code INT PRIMARY KEY)", -1},
		{"CREATE TABLE t(code INTEGER(4) PRIMARY KEY)", -1},
		{"CREATE TABLE t(a INTEGER, b INTEGER, PRIMARY KEY(a, b))", -1},
		{"CREATE TABLE t(a TEXT PRIMARY KEY)", -1},
		{"CREATE TABLE t(a INTEGER NOT NULL CONSTRAINT pk PRIMARY KEY)", 0},
		{"CREATE TABLE t(a INTEGER DEFAULT (1 + 2) CHECK (a > 0), b)", -1},
		{"CREATE TABLE t(a)", -1},
	}
	for _, tc := range cases {
		tab, err := ParseCreateTable(tc.sql)
		if err != nil {
			t.Errorf("%s: %v", tc.sql, err)
			continue
		}
		if tab.RowidAlias != tc.alias {
			t.Errorf("%s: alias = %d, want %d", tc.sql, tab.RowidAlias, tc.alias)
		}
	}
}

func TestParseCreateTableColumns(t *testing.T) {
	sql := `CREATE TEMP TABLE IF NOT EXISTS main."my table" ( -- comment
	  "quoted ""name""" NVARCHAR(160) NOT NULL,
	  ` + "`bt`" + ` NUMERIC(10, 2) DEFAULT 'a,b',
	  /* block, comment */ plain,
	  d DOUBLE PRECISION,
	  CHECK (bt > 0 AND plain IN (1,2)),
	  UNIQUE(d)
	)`
	tab, err := ParseCreateTable(sql)
	if err != nil {
		t.Fatal(err)
	}
	var names, types []string
	var affs []Affinity
	for _, c := range tab.Columns {
		names = append(names, c.Name)
		types = append(types, c.Type)
		affs = append(affs, c.Affinity)
	}
	if want := []string{`quoted "name"`, "bt", "plain", "d"}; !reflect.DeepEqual(names, want) {
		t.Errorf("names = %q, want %q", names, want)
	}
	if want := []string{"NVARCHAR ( 160 )", "NUMERIC ( 10 , 2 )", "", "DOUBLE PRECISION"}; !reflect.DeepEqual(types, want) {
		t.Errorf("types = %q, want %q", types, want)
	}
	if want := []Affinity{AffinityText, AffinityNumeric, AffinityBlob, AffinityReal}; !reflect.DeepEqual(affs, want) {
		t.Errorf("affinities = %v, want %v", affs, want)
	}
	if tab.Name != "my table" {
		t.Errorf("name = %q", tab.Name)
	}
	if tab.ColumnIndex("BT") != 1 || tab.ColumnIndex("nope") != -1 {
		t.Error("ColumnIndex should be case-insensitive")
	}
}

func TestParseCreateTableErrors(t *testing.T) {
	for _, sql := range []string{
		"", "SELECT 1", "CREATE INDEX i ON t(a)", "CREATE TABLE t", "CREATE TABLE t(a, b",
		"CREATE TABLE t()", "CREATE TABLE t(a 'unterminated)", "CREATE VIRTUAL TABLE t USING fts5(a)",
	} {
		if _, err := ParseCreateTable(sql); err == nil {
			t.Errorf("%q: expected error", sql)
		}
	}
}

func TestParseCreateIndex(t *testing.T) {
	ix, err := ParseCreateIndex(`CREATE UNIQUE INDEX IF NOT EXISTS main."ix 1" ON "T"(a COLLATE BINARY DESC, [b])`)
	if err != nil {
		t.Fatal(err)
	}
	if ix.Name != "ix 1" || ix.Table != "T" || !ix.Unique || !reflect.DeepEqual(ix.Columns, []string{"a", "b"}) {
		t.Errorf("unexpected index: %+v", ix)
	}
	if _, err := ParseCreateIndex("CREATE INDEX i ON"); err == nil {
		t.Error("expected error for truncated CREATE INDEX")
	}
}
