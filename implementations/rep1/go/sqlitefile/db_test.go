package sqlitefile

import (
	"bytes"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// miniDB builds the database from the worked example in the specification.
func miniDB(t *testing.T, pageSize int, leafCap, fan int) *DB {
	t.Helper()
	b := newBuilder(t, pageSize)
	rows := []testRow{
		{1, []Value{Null(), Text("Ada"), Int(36), Real(1.65), Blob([]byte{0, 1, 2})}},
		{2, []Value{Null(), Text("Grace"), Int(45), Real(1.7), Null()}},
		{3, []Value{Null(), Text("Alan"), Null(), Real(1.8), Blob(nil)}},
		{6, []Value{Null(), Text(""), Int(0), Int(0), Blob([]byte{0x7f})}}, // 0.0 stored as an integer
	}
	root := b.table(rows, leafCap, fan)
	b.addSchema("table", "people", "people", root, "CREATE TABLE people(\n    id INTEGER PRIMARY KEY,\n    name TEXT NOT NULL,\n    age INTEGER,\n    height REAL,\n    photo BLOB)")
	// index on age: entries (age, rowid), sorted; NULL first.
	entries := [][]Value{
		{Null(), Int(3)}, {Int(0), Int(6)}, {Int(36), Int(1)}, {Int(45), Int(2)},
	}
	ix := b.index(entries, leafCap, fan)
	b.addSchema("index", "people_age", "people", ix, "CREATE INDEX people_age ON people(age)")
	b.addSchema("index", "sqlite_autoindex_people_1", "people", 1, "")
	b.addSchema("view", "v", "v", 0, "CREATE VIEW v AS SELECT * FROM people")
	b.addSchema("trigger", "trg", "people", 0, "CREATE TRIGGER trg AFTER INSERT ON people BEGIN SELECT 1; END")
	db, err := OpenBytes(b.finish())
	if err != nil {
		t.Fatal(err)
	}
	return db
}

func run(t *testing.T, db *DB, line string) string {
	t.Helper()
	out, err := db.Exec(line, nil)
	if err != nil {
		return "error"
	}
	return string(out)
}

func TestWorkedExample(t *testing.T) {
	want := map[string]string{
		".tables": "people\n",
		"SELECT * FROM people": "1\tAda\t36\t1.65\t000102\n2\tGrace\t45\t1.7\tNULL\n" +
			"3\tAlan\tNULL\t1.8\t\n6\t\t0\t0.0\t7F\n",
		"SELECT name,height FROM people ORDER BY height DESC LIMIT 2": "Alan\t1.8\nGrace\t1.7\n",
		"SELECT name FROM people WHERE age IS NULL":                   "Alan\n",
		"SELECT name FROM people WHERE age > 40":                      "Grace\n",
		"SELECT rowid,name FROM people WHERE photo IS NOT NULL":       "1\tAda\n3\tAlan\n6\t\n",
		"INDEX people_age 45":                                         "2\tGrace\t45\t1.7\tNULL\n",
		"COUNT people":                                                "4\n",
		"SELECT nope FROM people":                                     "error",
	}
	// Run on a single-leaf layout and on a layout that forces interior pages.
	for _, shape := range [][2]int{{100, 100}, {1, 1}, {2, 2}} {
		db := miniDB(t, 1024, shape[0], shape[1])
		for q, w := range want {
			if got := run(t, db, q); got != w {
				t.Errorf("shape %v: %q = %q, want %q", shape, q, got, w)
			}
		}
	}
}

func TestSchemaAndTables(t *testing.T) {
	db := miniDB(t, 1024, 100, 100)
	got := run(t, db, ".schema people")
	want := "CREATE TABLE people(\n    id INTEGER PRIMARY KEY,\n    name TEXT NOT NULL,\n    age INTEGER,\n    height REAL,\n    photo BLOB);\n" +
		"CREATE INDEX people_age ON people(age);\n" +
		"CREATE TRIGGER trg AFTER INSERT ON people BEGIN SELECT 1; END;\n"
	if got != want {
		t.Errorf(".schema people = %q", got)
	}
	if got := run(t, db, ".schema PEOPLE"); got != want {
		t.Error(".schema must be case-insensitive")
	}
	for _, q := range []string{".schema people_age", ".schema trg", ".schema nosuch", ".schema sqlite_autoindex_people_1"} {
		if got := run(t, db, q); got != "" {
			t.Errorf("%s = %q, want empty", q, got)
		}
	}
	if got := run(t, db, ".schema v"); got != "CREATE VIEW v AS SELECT * FROM people;\n" {
		t.Errorf(".schema v = %q", got)
	}
}

func TestResolutionErrors(t *testing.T) {
	db := miniDB(t, 1024, 100, 100)
	for _, q := range []string{
		"SELECT * FROM v", "SELECT * FROM people_age", "SELECT * FROM trg", "SELECT * FROM sqlite_schema",
		"SELECT * FROM nosuch", "COUNT v", "COUNT sqlite_schema", "SELECT oid FROM people", "SELECT _rowid_ FROM people",
		"SELECT name FROM people WHERE nope = 1", "SELECT name FROM people ORDER BY nope",
		"INDEX people 1", "INDEX v 1", "INDEX sqlite_autoindex_people_1 1", "INDEX nosuch 1",
	} {
		if got := run(t, db, q); got != "error" {
			t.Errorf("%q = %q, want error", q, got)
		}
	}
	if _, err := db.Exec("SELECT * FROM nosuch", nil); !errors.Is(err, ErrNoSuchTable) {
		t.Errorf("want ErrNoSuchTable, got %v", err)
	}
	if _, err := db.Exec("SELECT zz FROM people", nil); !errors.Is(err, ErrNoSuchColumn) {
		t.Errorf("want ErrNoSuchColumn, got %v", err)
	}
	if _, err := db.Exec("INDEX people 1", nil); !errors.Is(err, ErrNoSuchIndex) {
		t.Errorf("want ErrNoSuchIndex, got %v", err)
	}
	out, err := db.Exec("COUNT nosuch", []byte("keep"))
	if err == nil || string(out) != "keep" {
		t.Errorf("on error Exec must return dst unchanged, got %q, %v", out, err)
	}
}

func TestSelectSemantics(t *testing.T) {
	db := miniDB(t, 1024, 2, 2)
	cases := map[string]string{
		"SELECT name FROM people WHERE age = NULL":                     "",
		"SELECT name FROM people WHERE age != 36":                      "Grace\n\n",
		"SELECT name FROM people WHERE age IS NOT 36":                  "Grace\nAlan\n\n",
		"SELECT name FROM people WHERE age = '45'":                     "Grace\n",
		"SELECT name FROM people WHERE age = 45.0":                     "Grace\n",
		"SELECT name FROM people WHERE name = 5":                       "",
		"SELECT name FROM people WHERE height = 0":                     "\n",
		"SELECT name FROM people WHERE height >= 1.7 AND age > 0":      "Grace\n",
		"SELECT name FROM people ORDER BY age":                         "Alan\n\nAda\nGrace\n",
		"SELECT name FROM people ORDER BY age DESC":                    "Grace\nAda\n\nAlan\n",
		"SELECT name FROM people ORDER BY photo DESC LIMIT 2":          "\nAda\n",
		"SELECT name FROM people LIMIT 0":                              "",
		"SELECT name FROM people LIMIT 2":                              "Ada\nGrace\n",
		"SELECT id, rowid FROM people WHERE id = 2":                    "2\t2\n",
		"SELECT name FROM people WHERE rowid >= 3 ORDER BY rowid DESC": "\nAlan\n",
		"INDEX people_age NULL":                                        "",
		"INDEX people_age '36'":                                        "1\tAda\t36\t1.65\t000102\n",
		"INDEX people_age 0":                                           "6\t\t0\t0.0\t7F\n",
		"INDEX people_age 7":                                           "",
	}
	for q, want := range cases {
		if got := run(t, db, q); got != want {
			t.Errorf("%q = %q, want %q", q, got, want)
		}
	}
}

func TestSelectResultAPI(t *testing.T) {
	db := miniDB(t, 1024, 2, 2)
	q, _ := ParseQuery("SELECT name, age FROM people WHERE age IS NOT NULL ORDER BY age DESC")
	res, err := db.Select(q)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(res.Columns, ",") != "name,age" || len(res.Rows) != 3 {
		t.Fatalf("unexpected result %+v", res)
	}
	if string(res.Rows[0][0].B) != "Grace" || res.Rows[0][1].I != 45 {
		t.Errorf("first row = %v", res.Rows[0])
	}
	r2, err := db.LookupIndex("people_age", Text("36"))
	if err != nil || len(r2.Rows) != 1 || string(r2.Rows[0][1].B) != "Ada" || len(r2.Columns) != 5 {
		t.Errorf("LookupIndex: %+v, %v", r2, err)
	}
	if n, err := db.Count("people"); err != nil || n != 4 {
		t.Errorf("Count = %d, %v", n, err)
	}
	if _, err := db.Select(&Query{Command: CmdCount}); err == nil {
		t.Error("Select of a non-SELECT query must fail")
	}
}

// bigDB builds tables that exercise deep trees, overflow chains, negative and
// extreme rowids, short records and index runs spanning interior pages.
func bigDB(t *testing.T, pageSize int) (*DB, []testRow) {
	t.Helper()
	b := newBuilder(t, pageSize)
	var rows []testRow
	for i := 1; i <= 200; i++ {
		var blob []byte
		switch {
		case i%17 == 0:
			blob = bytes.Repeat([]byte{byte(i)}, 3*pageSize+i) // multi-page overflow
		case i%5 == 0:
			blob = bytes.Repeat([]byte{byte(i)}, pageSize/4)
		}
		rows = append(rows, testRow{int64(i), []Value{
			Null(), Int(int64(i % 7)), Text(fmt.Sprintf("name-%03d", i)), Blob(blob),
		}})
	}
	root := b.table(rows, 4, 3)
	b.addSchema("table", "t", "t", root, "CREATE TABLE t(id INTEGER PRIMARY KEY, grp INT, name TEXT, data BLOB)")
	var entries [][]Value
	for g := 0; g < 7; g++ {
		for _, r := range rows {
			if r.vals[1].I == int64(g) {
				entries = append(entries, []Value{Int(int64(g)), Int(r.rowid)})
			}
		}
	}
	ix := b.index(entries, 5, 3)
	b.addSchema("index", "t_grp", "t", ix, "CREATE INDEX t_grp ON t(grp)")
	// An index whose keys overflow.
	var nentries [][]Value
	for _, r := range rows {
		nentries = append(nentries, []Value{Text(strings.Repeat("k", pageSize) + string(r.vals[2].B)), Int(r.rowid)})
	}
	nix := b.index(nentries, 3, 3)
	b.addSchema("index", "t_name", "t", nix, "CREATE INDEX t_name ON t(name)")
	db, err := OpenBytes(b.finish())
	if err != nil {
		t.Fatal(err)
	}
	return db, rows
}

func TestLargeTreesAndOverflow(t *testing.T) {
	for _, ps := range []int{512, 1024, 4096} {
		t.Run(fmt.Sprint(ps), func(t *testing.T) {
			db, rows := bigDB(t, ps)
			if n, err := db.Count("t"); err != nil || n != int64(len(rows)) {
				t.Fatalf("Count = %d, %v", n, err)
			}
			res, err := db.Select(mustParse(t, "SELECT * FROM t"))
			if err != nil || len(res.Rows) != len(rows) {
				t.Fatalf("select all: %d rows, %v", len(res.Rows), err)
			}
			for i, r := range res.Rows {
				want := rows[i]
				if r[0].I != want.rowid || r[1].I != want.vals[1].I || !bytes.Equal(r[2].B, want.vals[2].B) || !bytes.Equal(r[3].B, want.vals[3].B) {
					t.Fatalf("row %d mismatch", i)
				}
			}
			// Index run spanning many pages: all rows with grp = 3, ascending rowid.
			res, err = db.LookupIndex("t_grp", Int(3))
			if err != nil {
				t.Fatal(err)
			}
			var wantIDs []int64
			for _, r := range rows {
				if r.vals[1].I == 3 {
					wantIDs = append(wantIDs, r.rowid)
				}
			}
			if len(res.Rows) != len(wantIDs) {
				t.Fatalf("grp=3: %d rows, want %d", len(res.Rows), len(wantIDs))
			}
			for i, r := range res.Rows {
				if r[0].I != wantIDs[i] {
					t.Fatalf("grp=3 row %d: id %d, want %d", i, r[0].I, wantIDs[i])
				}
			}
			// Every group, via both the index and a scan, must agree.
			for g := 0; g < 7; g++ {
				a, _ := db.Exec(fmt.Sprintf("INDEX t_grp %d", g), nil)
				b, _ := db.Exec(fmt.Sprintf("SELECT * FROM t WHERE grp = %d", g), nil)
				if !bytes.Equal(a, b) || len(a) == 0 {
					t.Errorf("group %d: index and scan disagree", g)
				}
			}
			if out, _ := db.Exec("INDEX t_grp 99", nil); len(out) != 0 {
				t.Error("missing key must give no rows")
			}
			// Index keys that overflow.
			out, err := db.Exec("INDEX t_name '"+strings.Repeat("k", ps)+"name-137'", nil)
			if err != nil || !strings.HasPrefix(string(out), "137\t") {
				t.Errorf("overflowing index key lookup: %q, %v", out, err)
			}
			// ORDER BY with ties broken by ascending rowid in both directions.
			out, _ = db.Exec("SELECT id FROM t WHERE grp = 2 ORDER BY grp DESC LIMIT 3", nil)
			if string(out) != "2\n9\n16\n" {
				t.Errorf("DESC tie order = %q", out)
			}
			out, _ = db.Exec("SELECT id FROM t ORDER BY grp LIMIT 3", nil)
			if string(out) != "7\n14\n21\n" {
				t.Errorf("ASC tie order = %q", out)
			}
		})
	}
}

func mustParse(t *testing.T, s string) *Query {
	t.Helper()
	q, err := ParseQuery(s)
	if err != nil {
		t.Fatal(err)
	}
	return q
}

func TestRowidsAndShortRecords(t *testing.T) {
	b := newBuilder(t, 512)
	ids := []int64{-9223372036854775808, -300, -1, 0, 5, 128, 1 << 40, 9223372036854775807}
	var rows []testRow
	for _, id := range ids {
		// Records with only one column: as after ALTER TABLE ADD COLUMN.
		rows = append(rows, testRow{id, []Value{Text(fmt.Sprint("r", id))}})
	}
	root := b.table(rows, 3, 2)
	b.addSchema("table", "t", "t", root, "CREATE TABLE t(a TEXT, b INTEGER, c REAL)")
	db, err := OpenBytes(b.finish())
	if err != nil {
		t.Fatal(err)
	}
	out, err := db.Exec("SELECT rowid, a, b, c FROM t", nil)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if len(lines) != len(ids) {
		t.Fatalf("got %d lines", len(lines))
	}
	for i, id := range ids {
		if want := fmt.Sprintf("%d\tr%d\tNULL\tNULL", id, id); lines[i] != want {
			t.Errorf("line %d = %q, want %q", i, lines[i], want)
		}
	}
	if out, _ := db.Exec("SELECT a FROM t WHERE rowid = -9223372036854775808", nil); string(out) != "r-9223372036854775808\n" {
		t.Errorf("min rowid lookup = %q", out)
	}
	if out, _ := db.Exec("SELECT a FROM t WHERE rowid < -1", nil); string(out) != "r-9223372036854775808\nr-300\n" {
		t.Errorf("negative rowid range = %q", out)
	}
}

func TestExactInt64Comparison(t *testing.T) {
	b := newBuilder(t, 512)
	rows := []testRow{
		{1, []Value{Int(9223372036854775806)}},
		{2, []Value{Int(9223372036854775807)}},
		{3, []Value{Int(1<<53 + 1)}},
	}
	b.addSchema("table", "t", "t", b.table(rows, 10, 10), "CREATE TABLE t(n INTEGER)")
	db, err := OpenBytes(b.finish())
	if err != nil {
		t.Fatal(err)
	}
	if got := run(t, db, "SELECT rowid FROM t WHERE n = '9223372036854775807'"); got != "2\n" {
		t.Errorf("text literal lost precision: %q", got)
	}
	if got := run(t, db, "SELECT rowid FROM t WHERE n = 9007199254740993"); got != "3\n" {
		t.Errorf("got %q", got)
	}
}

func TestOpenErrors(t *testing.T) {
	if _, err := OpenBytes([]byte("not a database")); !errors.Is(err, ErrNotDatabase) {
		t.Errorf("want ErrNotDatabase, got %v", err)
	}
	if _, err := OpenBytes(nil); !errors.Is(err, ErrNotDatabase) {
		t.Errorf("want ErrNotDatabase, got %v", err)
	}
	if _, err := Open("/nonexistent/file.sqlite"); err == nil {
		t.Error("expected error for missing file")
	}
}

// Corrupting a valid image must produce errors, never panics or hangs.
func TestCorruptImagesDoNotPanic(t *testing.T) {
	good := miniDB(t, 1024, 1, 1)
	img := good.pager.data
	for seed := 0; seed < 400; seed++ {
		bad := append([]byte{}, img...)
		x := uint32(seed*2654435761 + 1)
		for k := 0; k < 4; k++ {
			x = x*1664525 + 1013904223
			pos := int(x>>8) % len(bad)
			if pos < 16 && seed%2 == 0 {
				continue
			}
			bad[pos] = byte(x)
		}
		db, err := OpenBytes(bad)
		if err != nil {
			continue
		}
		for _, q := range []string{".tables", "COUNT people", "SELECT * FROM people", "SELECT * FROM people ORDER BY name", "INDEX people_age 45", ".schema people"} {
			db.Exec(q, nil)
		}
	}
	// A page that points at itself must be detected.
	b := newBuilder(t, 512)
	rows := []testRow{{1, []Value{Int(1)}}, {2, []Value{Int(2)}}}
	root := b.table(rows, 1, 1)
	b.addSchema("table", "t", "t", root, "CREATE TABLE t(a)")
	data := b.finish()
	pg := data[(int(root)-1)*512:]
	pg[8], pg[9], pg[10], pg[11] = 0, 0, 0, byte(root) // right child -> itself
	db, err := OpenBytes(data)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("SELECT * FROM t", nil); err == nil {
		t.Error("cyclic tree should be reported as corrupt")
	}
}

func TestTablesFiltersInternalNames(t *testing.T) {
	b := newBuilder(t, 512)
	for _, n := range []string{"zeta", "Alpha", "sqlite_sequence", "SQLite_x", "beta"} {
		b.addSchema("table", n, n, b.table(nil, 4, 4), "CREATE TABLE "+n+"(a)")
	}
	b.addSchema("view", "aview", "aview", 0, "CREATE VIEW aview AS SELECT 1")
	db, err := OpenBytes(b.finish())
	if err != nil {
		t.Fatal(err)
	}
	if got := run(t, db, ".tables"); got != "Alpha\nbeta\nzeta\n" {
		t.Errorf(".tables = %q", got)
	}
	if got := run(t, db, "SELECT * FROM sqlite_sequence"); got != "" {
		t.Errorf("sqlite_sequence is readable like any table, got %q", got)
	}
	if got := run(t, db, "COUNT SQLITE_X"); got != "0\n" {
		t.Errorf("COUNT = %q", got)
	}
}
