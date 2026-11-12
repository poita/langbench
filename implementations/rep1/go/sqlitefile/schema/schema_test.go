package schema

import (
	"reflect"
	"testing"

	"sqlitefile/value"
)

func TestParseTable(t *testing.T) {
	tests := []struct {
		name    string
		sql     string
		cols    []string
		types   []string
		aff     []value.Affinity
		aliasAt int
	}{
		{
			name:    "plain rowid alias",
			sql:     "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, height REAL, photo BLOB)",
			cols:    []string{"id", "name", "age", "height", "photo"},
			types:   []string{"INTEGER", "TEXT", "INTEGER", "REAL", "BLOB"},
			aff:     []value.Affinity{value.AffinityInteger, value.AffinityText, value.AffinityInteger, value.AffinityReal, value.AffinityBlob},
			aliasAt: 0,
		},
		{
			name:    "chinook table constraint",
			sql:     "CREATE TABLE [Album]\n(\n    [AlbumId] INTEGER  NOT NULL,\n    [Title] NVARCHAR(160)  NOT NULL,\n    CONSTRAINT [PK_Album] PRIMARY KEY  ([AlbumId]),\n    FOREIGN KEY ([ArtistId]) REFERENCES [Artist] ([ArtistId])\n)",
			cols:    []string{"AlbumId", "Title"},
			types:   []string{"INTEGER", "NVARCHAR ( 160 )"},
			aff:     []value.Affinity{value.AffinityInteger, value.AffinityText},
			aliasAt: 0,
		},
		{
			name:    "column PRIMARY KEY DESC is not an alias",
			sql:     "CREATE TABLE t(x INTEGER PRIMARY KEY DESC, y)",
			cols:    []string{"x", "y"},
			types:   []string{"INTEGER", ""},
			aff:     []value.Affinity{value.AffinityInteger, value.AffinityBlob},
			aliasAt: -1,
		},
		{
			name:    "table PRIMARY KEY DESC is an alias",
			sql:     "CREATE TABLE t(x INTEGER, y TEXT, PRIMARY KEY(x DESC))",
			cols:    []string{"x", "y"},
			types:   []string{"INTEGER", "TEXT"},
			aff:     []value.Affinity{value.AffinityInteger, value.AffinityText},
			aliasAt: 0,
		},
		{
			name:    "INT is not an alias",
			sql:     "CREATE TABLE t(code INT PRIMARY KEY, v)",
			cols:    []string{"code", "v"},
			types:   []string{"INT", ""},
			aff:     []value.Affinity{value.AffinityInteger, value.AffinityBlob},
			aliasAt: -1,
		},
		{
			name:    "composite key is not an alias",
			sql:     "CREATE TABLE t(a INTEGER, b INTEGER, PRIMARY KEY(a, b))",
			cols:    []string{"a", "b"},
			types:   []string{"INTEGER", "INTEGER"},
			aff:     []value.Affinity{value.AffinityInteger, value.AffinityInteger},
			aliasAt: -1,
		},
		{
			name:    "quoting, comments and defaults",
			sql:     "CREATE TEMP TABLE IF NOT EXISTS main.\"my \"\"t\"\"\" (\n -- comment, with comma\n `a b` TEXT DEFAULT 'x,(y',\n \"c\" /* , */ NUMERIC(10,2) CHECK (c > 0), d)",
			cols:    []string{"a b", "c", "d"},
			types:   []string{"TEXT", "NUMERIC ( 10 , 2 )", ""},
			aff:     []value.Affinity{value.AffinityText, value.AffinityNumeric, value.AffinityBlob},
			aliasAt: -1,
		},
		{
			name:    "multi-word types",
			sql:     "CREATE TABLE t(a DOUBLE PRECISION, b FLOATING POINT, c STRING, d UNSIGNED BIG INT)",
			cols:    []string{"a", "b", "c", "d"},
			types:   []string{"DOUBLE PRECISION", "FLOATING POINT", "STRING", "UNSIGNED BIG INT"},
			aff:     []value.Affinity{value.AffinityReal, value.AffinityInteger, value.AffinityNumeric, value.AffinityInteger},
			aliasAt: -1,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			def, err := ParseTable(tc.sql)
			if err != nil {
				t.Fatal(err)
			}
			var cols, types []string
			var aff []value.Affinity
			for _, c := range def.Columns {
				cols = append(cols, c.Name)
				types = append(types, c.Type)
				aff = append(aff, c.Affinity)
			}
			if !reflect.DeepEqual(cols, tc.cols) {
				t.Errorf("columns = %q, want %q", cols, tc.cols)
			}
			if !reflect.DeepEqual(types, tc.types) {
				t.Errorf("types = %q, want %q", types, tc.types)
			}
			if !reflect.DeepEqual(aff, tc.aff) {
				t.Errorf("affinities = %v, want %v", aff, tc.aff)
			}
			if got := def.RowidAlias(); got != tc.aliasAt {
				t.Errorf("RowidAlias = %d, want %d", got, tc.aliasAt)
			}
		})
	}
}

func TestParseTableErrors(t *testing.T) {
	for _, sql := range []string{"", "SELECT 1", "CREATE INDEX i ON t(a)", "CREATE TABLE t"} {
		if _, err := ParseTable(sql); err == nil {
			t.Errorf("ParseTable(%q) succeeded, want an error", sql)
		}
	}
}

func TestParseIndex(t *testing.T) {
	tests := []struct {
		sql  string
		want []string
	}{
		{"CREATE INDEX people_age ON people(age)", []string{"age"}},
		{"CREATE UNIQUE INDEX IF NOT EXISTS \"i x\" ON main.t (\"a\" COLLATE BINARY DESC, [b] ASC)", []string{"a", "b"}},
		{"CREATE INDEX on_t ON t(c)", []string{"c"}},
	}
	for _, tc := range tests {
		def, err := ParseIndex(tc.sql)
		if err != nil {
			t.Errorf("ParseIndex(%q): %v", tc.sql, err)
			continue
		}
		if !reflect.DeepEqual(def.Columns, tc.want) {
			t.Errorf("ParseIndex(%q) = %q, want %q", tc.sql, def.Columns, tc.want)
		}
	}
	if _, err := ParseIndex("CREATE INDEX i"); err == nil {
		t.Error("expected an error for an index without a column list")
	}
}

func TestEqualFold(t *testing.T) {
	if !EqualFold("People", "pEOPLE") || EqualFold("a", "ab") || EqualFold("é", "É") {
		t.Error("EqualFold must be ASCII case-insensitive only")
	}
}
