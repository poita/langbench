package sqlitefile_test

import (
	"fmt"
	"strings"
	"testing"

	"sqlitefile"
)

func open(t testing.TB, name string) *sqlitefile.DB {
	t.Helper()
	db, err := sqlitefile.Open("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return db
}

func exec(t testing.TB, db *sqlitefile.DB, q string) string {
	t.Helper()
	lines, err := db.Exec(q)
	if err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return strings.Join(lines, "\n")
}

func TestMini(t *testing.T) {
	db := open(t, "mini.sqlite")
	tests := []struct{ q, want string }{
		{".tables", "kv\npeople\nseq"},
		{"SELECT * FROM people", "1\tAda\t36\t1.65\t000102\n2\tGrace\t45\t1.7\tNULL\n3\tAlan\tNULL\t1.8\t\n6\t\t0\t0.0\t7F"},
		{"SELECT name,height FROM people ORDER BY height DESC LIMIT 2", "Alan\t1.8\nGrace\t1.7"},
		{"SELECT name FROM people WHERE age IS NULL", "Alan"},
		{"SELECT name FROM people WHERE age > 40", "Grace"},
		{"SELECT name FROM people WHERE age != 36", "Grace\n"},
		{"SELECT rowid,name FROM people WHERE photo IS NOT NULL", "1\tAda\n3\tAlan\n6\t"},
		{"SELECT name FROM people WHERE age = '45'", "Grace"},
		{"SELECT name FROM people ORDER BY age", "Alan\n\nAda\nGrace"},
		{"SELECT name FROM people ORDER BY age DESC", "Grace\nAda\n\nAlan"},
		{"SELECT name FROM people LIMIT 0", ""},
		{"SELECT name FROM people WHERE name = 'nobody'", ""},
		{"INDEX people_age 45", "2\tGrace\t45\t1.7\tNULL"},
		{"INDEX people_age '45'", "2\tGrace\t45\t1.7\tNULL"},
		{"INDEX people_age NULL", ""},
		{"INDEX people_age 7", ""},
		{"COUNT people", "4"},
		{"COUNT PEOPLE", "4"},
		// kv.k is INT PRIMARY KEY: not a rowid alias, values are in the record.
		{"SELECT rowid,k,v FROM kv", "1\t10\tten\n2\t2\ttwo"},
		{"SELECT * FROM seq", "1\ta\n2\tb"},
		{"COUNT sqlite_sequence", "1"},
		{"SELECT * FROM sqlite_sequence", "seq\t2"},
		{".schema seq", "CREATE TABLE seq(id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT);"},
		{".schema nothing", ""},
		{".schema adults", "CREATE VIEW adults AS SELECT name FROM people WHERE age >= 18;"},
		{".schema people_age", ""},
	}
	for _, tc := range tests {
		if got := exec(t, db, tc.q); got != tc.want {
			t.Errorf("%s\n got: %q\nwant: %q", tc.q, got, tc.want)
		}
	}
}

func TestMiniSchemaInterleaving(t *testing.T) {
	db := open(t, "mini.sqlite")
	got := exec(t, db, ".schema people")
	for _, want := range []string{"CREATE TABLE people(\n    id INTEGER PRIMARY KEY,", "CREATE INDEX people_age ON people(age);", "CREATE TRIGGER people_t AFTER INSERT ON people BEGIN SELECT 1; END;"} {
		if !strings.Contains(got, want) {
			t.Errorf(".schema people lacks %q:\n%s", want, got)
		}
	}
	if strings.Index(got, "CREATE TABLE") > strings.Index(got, "CREATE INDEX") {
		t.Error("statements are not in schema order")
	}
}

func TestMiniErrors(t *testing.T) {
	db := open(t, "mini.sqlite")
	bad := []string{
		"SELECT nope FROM people",
		"SELECT name FROM nope",
		"SELECT name FROM people WHERE nope = 1",
		"SELECT name FROM people ORDER BY nope",
		"SELECT * FROM adults",        // a view
		"SELECT * FROM people_age",    // an index
		"SELECT * FROM people_t",      // a trigger
		"SELECT * FROM sqlite_schema", // not one of its own rows
		"SELECT oid FROM people",      // only "rowid" is recognised
		"SELECT _rowid_ FROM people",
		"COUNT adults",
		"COUNT nope",
		"INDEX people 1",                // a table
		"INDEX adults 1",                // a view
		"INDEX sqlite_autoindex_kv_1 1", // auto-created
		"INDEX nope 1",
		"SELECT name FROM people WHERE age == 1",
		".SCHEMA people",
	}
	for _, q := range bad {
		if lines, err := db.Exec(q); err == nil {
			t.Errorf("%s: expected an error, got %q", q, lines)
		}
	}
}

func TestBig(t *testing.T) {
	db := open(t, "big.sqlite")
	one := func(q, want string) {
		t.Helper()
		if got := exec(t, db, q); got != want {
			t.Errorf("%s\n got: %q\nwant: %q", q, got, want)
		}
	}
	one("COUNT items", "3002")
	one("SELECT n,grp,label,score FROM items WHERE n = -9000000000", "-9000000000\t3\tneg-big\t1.5")
	one("SELECT n,grp,label,score FROM items WHERE n=-5", "-5\t3\tneg\t0.0")
	one("SELECT n,grp,label,score FROM items WHERE n = 7", "7\t0\tlabel-7\t1.75")
	one("SELECT n,grp,label,score FROM items WHERE n = 2999", "2999\t3\tlabel-2999\t749.75")
	one("SELECT n FROM items ORDER BY n LIMIT 3", "-9000000000\n-5\n1")
	one("SELECT n FROM items WHERE grp = 3 ORDER BY n LIMIT 3", "-9000000000\n-5\n3")
	one("SELECT n FROM items ORDER BY score DESC LIMIT 3", "3000\n2999\n2998")
	one("INDEX items_label 'label-1234'", "1234\t2\tlabel-1234\t"+strings.Repeat("00", 1234%40)+"\t308.5")

	// Index lookups agree with a full scan and come back in rowid order.
	for _, grp := range []int{0, 3, 6} {
		scan := exec(t, db, fmt.Sprintf("SELECT * FROM items WHERE grp = %d", grp))
		idx := exec(t, db, fmt.Sprintf("INDEX items_grp %d", grp))
		if scan != idx {
			t.Errorf("INDEX items_grp %d differs from the scan", grp)
		}
		if scan == "" {
			t.Errorf("grp %d should have rows", grp)
		}
	}
	if got := strings.Count(exec(t, db, "INDEX items_grp 3"), "\n") + 1; got != 431 {
		t.Errorf("grp 3 has %d rows, want 431", got)
	}
	// TEXT-affinity column compared with a number: the literal becomes text.
	one("INDEX items_label 5", "")
	// A random 2000-byte blob in an overflowing row (n = 100, 200, ...).
	for _, n := range []int{100, 2000, 3000} {
		line := exec(t, db, fmt.Sprintf("SELECT payload FROM items WHERE n = %d", n))
		if len(line) != 4000 {
			t.Errorf("payload of row %d has %d hex digits, want 4000", n, len(line))
		}
	}
	// Multi-column indexes are not usable with INDEX.
	if _, err := db.Exec("INDEX items_two 3"); err == nil {
		t.Error("INDEX on a two-column index should fail")
	}
}

func TestOpenErrors(t *testing.T) {
	if _, err := sqlitefile.Open("testdata/missing.sqlite"); err == nil {
		t.Error("expected an error for a missing file")
	}
	if _, err := sqlitefile.OpenBytes([]byte("hello")); err == nil {
		t.Error("expected an error for a non-database")
	}
}

func ExampleDB_Exec() {
	db, err := sqlitefile.Open("testdata/mini.sqlite")
	if err != nil {
		panic(err)
	}
	lines, err := db.Exec("SELECT name FROM people WHERE age > 30 ORDER BY name DESC")
	if err != nil {
		panic(err)
	}
	for _, l := range lines {
		fmt.Println(l)
	}
	// Output:
	// Grace
	// Ada
}

func BenchmarkScan(b *testing.B) {
	db := open(b, "big.sqlite")
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := db.Exec("SELECT * FROM items WHERE grp = 3"); err != nil {
			b.Fatal(err)
		}
	}
}
