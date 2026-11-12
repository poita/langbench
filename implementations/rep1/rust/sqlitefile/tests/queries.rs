//! End-to-end tests: build a database file in memory, run queries against it.

mod common;

use common::*;
use sqlitefile::{Engine, Value};

/// The `people` database from the worked example in the specification.
fn mini() -> Engine {
    let mut b = DbBuilder::new(4096);
    let rows = vec![
        (1, record(&[Value::Null, text("Ada"), int(36), Value::Real(1.65), Value::Blob(vec![0, 1, 2])])),
        (2, record(&[Value::Null, text("Grace"), int(45), Value::Real(1.7), Value::Null])),
        (3, record(&[Value::Null, text("Alan"), Value::Null, Value::Real(1.8), Value::Blob(vec![])])),
        // 0.0 is stored as the integer 0 in a REAL column.
        (6, record(&[Value::Null, text(""), int(0), int(0), Value::Blob(vec![0x7f])])),
    ];
    let root = b.table(&rows, 100);
    let mut idx: Vec<(Value, i64)> = vec![
        (int(36), 1),
        (int(45), 2),
        (Value::Null, 3),
        (int(0), 6),
    ];
    idx.sort_by(|a, b| a.0.compare(&b.0));
    let entries: Vec<Vec<u8>> = idx.iter().map(|(k, r)| record(&[k.clone(), int(*r)])).collect();
    let iroot = b.index(&entries, 100);
    b.schema_row(
        "table",
        "people",
        "people",
        root,
        Some("CREATE TABLE people(\n    id INTEGER PRIMARY KEY,\n    name TEXT NOT NULL,\n    age INTEGER,\n    height REAL,\n    photo BLOB)"),
    );
    b.schema_row("index", "people_age", "people", iroot, Some("CREATE INDEX people_age ON people(age)"));
    Engine::from_bytes(b.finish()).unwrap()
}

fn run(e: &Engine, q: &str) -> String {
    e.execute_or_error(q)
}

#[test]
fn spec_worked_example() {
    let e = mini();
    assert_eq!(run(&e, ".tables"), "people\n");
    assert_eq!(
        run(&e, "SELECT * FROM people"),
        "1\tAda\t36\t1.65\t000102\n2\tGrace\t45\t1.7\tNULL\n3\tAlan\tNULL\t1.8\t\n6\t\t0\t0.0\t7F\n"
    );
    assert_eq!(run(&e, "SELECT name,height FROM people ORDER BY height DESC LIMIT 2"), "Alan\t1.8\nGrace\t1.7\n");
    assert_eq!(run(&e, "SELECT name FROM people WHERE age IS NULL"), "Alan\n");
    assert_eq!(run(&e, "SELECT name FROM people WHERE age > 40"), "Grace\n");
    assert_eq!(run(&e, "SELECT rowid,name FROM people WHERE photo IS NOT NULL"), "1\tAda\n3\tAlan\n6\t\n");
    assert_eq!(run(&e, "INDEX people_age 45"), "2\tGrace\t45\t1.7\tNULL\n");
    assert_eq!(run(&e, "COUNT people"), "4\n");
    assert_eq!(run(&e, "SELECT nope FROM people"), "error\n");
}

#[test]
fn where_semantics() {
    let e = mini();
    // NULL compares false under the six operators, IS is NULL-safe.
    assert_eq!(run(&e, "SELECT id FROM people WHERE age != 36"), "2\n6\n");
    assert_eq!(run(&e, "SELECT id FROM people WHERE age IS NOT 36"), "2\n3\n6\n");
    assert_eq!(run(&e, "SELECT id FROM people WHERE age = NULL"), "");
    // Text affinity: numeric literal converted to text, then compared.
    assert_eq!(run(&e, "SELECT id FROM people WHERE name = 5"), "");
    // Integer affinity: numeric-looking text literal becomes a number.
    assert_eq!(run(&e, "SELECT id FROM people WHERE age = ' 36 '"), "1\n");
    assert_eq!(run(&e, "SELECT id FROM people WHERE age >= '36.0e0' AND age < 46"), "1\n2\n");
    // The rowid pseudo-column and the alias agree.
    assert_eq!(run(&e, "SELECT id FROM people WHERE rowid > 2 ORDER BY rowid DESC"), "6\n3\n");
    assert_eq!(run(&e, "SELECT rowid FROM people WHERE id = 6"), "6\n");
    // REAL-affinity column, integer literal.
    assert_eq!(run(&e, "SELECT name FROM people WHERE height = 0"), "\n");
}

#[test]
fn ordering_and_limit() {
    let e = mini();
    // NULLs first ascending, last descending; ties by ascending rowid.
    assert_eq!(run(&e, "SELECT id FROM people ORDER BY age"), "3\n6\n1\n2\n");
    assert_eq!(run(&e, "SELECT id FROM people ORDER BY age DESC"), "2\n1\n6\n3\n");
    assert_eq!(run(&e, "SELECT id FROM people ORDER BY photo"), "2\n3\n1\n6\n");
    assert_eq!(run(&e, "SELECT id FROM people LIMIT 0"), "");
    assert_eq!(run(&e, "SELECT id FROM people LIMIT 2"), "1\n2\n");
    assert_eq!(run(&e, "SELECT id FROM people ORDER BY age DESC LIMIT 1"), "2\n");
}

#[test]
fn errors() {
    let e = mini();
    for q in [
        ".SCHEMA people",
        ".tables extra",
        "SELECT * FROM nope",
        "SELECT * FROM people WHERE age == 1",
        "SELECT oid FROM people",
        "COUNT sqlite_schema",
        "COUNT people_age",
        "SELECT * FROM people_age",
        "INDEX nope 1",
        "INDEX people 1",
        "INDEX people_age",
        "SELECT * FROM people LIMIT -1",
        "bogus",
    ] {
        assert_eq!(run(&e, q), "error\n", "{q}");
    }
    assert_eq!(run(&e, ".schema nope"), "");
    assert_eq!(run(&e, "INDEX people_age NULL"), "");
}

#[test]
fn schema_command() {
    let e = mini();
    let out = run(&e, ".schema PEOPLE");
    assert!(out.starts_with("CREATE TABLE people(\n    id INTEGER PRIMARY KEY,"));
    assert!(out.ends_with("photo BLOB);\nCREATE INDEX people_age ON people(age);\n"));
    assert_eq!(run(&e, ".schema people_age"), "");
}

#[test]
fn multi_level_table_and_extreme_rowids() {
    let mut b = DbBuilder::new(512);
    let mut rowids: Vec<i64> = vec![i64::MIN, -1_000_000_000_000, -129, -1, 0, 1, 127, 128, 16383, 16384, 1 << 40, 1 << 56, i64::MAX];
    rowids.sort();
    let rows: Vec<(i64, Vec<u8>)> = rowids
        .iter()
        .map(|&r| (r, record(&[text(&format!("r{r}"))])))
        .collect();
    let root = b.table(&rows, 3);
    b.schema_row("table", "t", "t", root, Some("CREATE TABLE t(label TEXT)"));
    let e = Engine::from_bytes(b.finish()).unwrap();
    assert_eq!(run(&e, "COUNT t"), "13\n");
    let all = run(&e, "SELECT rowid FROM t");
    let got: Vec<i64> = all.lines().map(|l| l.parse().unwrap()).collect();
    assert_eq!(got, rowids);
    assert_eq!(run(&e, "SELECT label FROM t WHERE rowid = -9223372036854775808"), "r-9223372036854775808\n");
    assert_eq!(run(&e, "SELECT rowid FROM t WHERE rowid < -1 LIMIT 2"), "-9223372036854775808\n-1000000000000\n");
    assert_eq!(run(&e, "SELECT rowid FROM t ORDER BY rowid DESC LIMIT 1"), "9223372036854775807\n");
}

#[test]
fn many_rows_with_interior_pages() {
    let mut b = DbBuilder::new(1024);
    let rows: Vec<(i64, Vec<u8>)> = (1..=2000)
        .map(|i| (i, record(&[int(i % 7), text(&format!("name{i}"))])))
        .collect();
    let root = b.table(&rows, 20);
    b.schema_row("table", "t", "t", root, Some("CREATE TABLE t(k INTEGER, name TEXT)"));
    let e = Engine::from_bytes(b.finish()).unwrap();
    assert_eq!(run(&e, "COUNT t"), "2000\n");
    assert_eq!(run(&e, "SELECT name FROM t WHERE rowid = 1234"), "name1234\n");
    assert_eq!(run(&e, "SELECT rowid FROM t WHERE k = 3 LIMIT 3"), "3\n10\n17\n");
    assert_eq!(run(&e, "SELECT rowid FROM t WHERE k = 6 ORDER BY rowid DESC LIMIT 2"), "1994\n1987\n");
    let ordered = run(&e, "SELECT k,rowid FROM t ORDER BY k DESC LIMIT 2");
    assert_eq!(ordered, "6\t6\n6\t13\n");
}

#[test]
fn overflow_payloads_around_thresholds() {
    for page_size in [512usize, 1024] {
        let u = page_size;
        let x_table = u - 35;
        let m = (u - 12) * 32 / 255 - 23;
        let mut sizes = vec![x_table - 20, x_table - 11, x_table - 10, x_table, x_table + 5, m, 3 * u, 5 * u + 17];
        sizes.sort();
        let mut b = DbBuilder::new(page_size);
        let rows: Vec<(i64, Vec<u8>)> = sizes
            .iter()
            .enumerate()
            .map(|(i, &n)| {
                let blob: Vec<u8> = (0..n).map(|j| (j * 31 + i) as u8).collect();
                (i as i64 + 1, record(&[Value::Blob(blob)]))
            })
            .collect();
        let root = b.table(&rows, 1);
        b.schema_row("table", "t", "t", root, Some("CREATE TABLE t(data BLOB)"));
        let e = Engine::from_bytes(b.finish()).unwrap();
        let out = run(&e, "SELECT data FROM t");
        for (i, (line, &n)) in out.lines().zip(&sizes).enumerate() {
            assert_eq!(line.len(), 2 * n, "row {i} of page size {page_size}");
            let expect: String = (0..n).map(|j| format!("{:02X}", (j * 31 + i) as u8)).collect();
            assert_eq!(line, expect, "row {i} of page size {page_size}");
        }
        assert_eq!(out.lines().count(), sizes.len());
    }
}

#[test]
fn index_lookup_through_interior_entries() {
    let mut b = DbBuilder::new(512);
    // 300 rows, key = id % 3 stored as text; many equal keys span subtrees.
    let n = 300;
    let rows: Vec<(i64, Vec<u8>)> = (1..=n)
        .map(|i| (i, record(&[Value::Null, text(&format!("k{}", i % 3)), text(&format!("v{i}"))])))
        .collect();
    let troot = b.table(&rows, 10);
    let mut entries: Vec<(String, i64)> = (1..=n).map(|i| (format!("k{}", i % 3), i)).collect();
    entries.sort();
    let recs: Vec<Vec<u8>> = entries
        .iter()
        .map(|(k, r)| record(&[text(k), int(*r)]))
        .collect();
    let iroot = b.index(&recs, 12);
    b.schema_row("table", "t", "t", troot, Some("CREATE TABLE t(id INTEGER PRIMARY KEY, grp TEXT, v TEXT)"));
    b.schema_row("index", "t_grp", "t", iroot, Some("CREATE INDEX t_grp ON t(grp)"));
    b.schema_row("index", "sqlite_autoindex_t_1", "t", 0, None);
    let e = Engine::from_bytes(b.finish()).unwrap();

    for g in 0..3 {
        let out = run(&e, &format!("INDEX t_grp 'k{g}'"));
        let want: String = (1..=n)
            .filter(|i| i % 3 == g)
            .map(|i| format!("{i}\tk{g}\tv{i}\n"))
            .collect();
        assert_eq!(out, want, "group {g}");
    }
    assert_eq!(run(&e, "INDEX t_grp 'k3'"), "");
    assert_eq!(run(&e, "INDEX t_grp 'a'"), "");
    assert_eq!(run(&e, "INDEX t_grp 'zzz'"), "");
    assert_eq!(run(&e, "INDEX t_grp 5"), "");
    assert_eq!(run(&e, "INDEX sqlite_autoindex_t_1 1"), "error\n");
}

#[test]
fn index_applies_column_affinity_to_literal() {
    let mut b = DbBuilder::new(1024);
    let rows = vec![
        (1, record(&[Value::Null, int(10), text("10")])),
        (2, record(&[Value::Null, int(20), text("20")])),
    ];
    let troot = b.table(&rows, 10);
    let i1 = b.index(&[record(&[int(10), int(1)]), record(&[int(20), int(2)])], 10);
    let i2 = b.index(&[record(&[text("10"), int(1)]), record(&[text("20"), int(2)])], 10);
    b.schema_row("table", "t", "t", troot, Some("CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER, s VARCHAR(5))"));
    b.schema_row("index", "t_n", "t", i1, Some("CREATE INDEX t_n ON t(n)"));
    b.schema_row("index", "t_s", "t", i2, Some("CREATE INDEX t_s ON t(s)"));
    b.schema_row("index", "t_both", "t", i2, Some("CREATE INDEX t_both ON t(n, s)"));
    let e = Engine::from_bytes(b.finish()).unwrap();
    assert_eq!(run(&e, "INDEX t_n '20'"), "2\t20\t20\n");
    assert_eq!(run(&e, "INDEX t_n 20.0"), "2\t20\t20\n");
    assert_eq!(run(&e, "INDEX t_s 10"), "1\t10\t10\n");
    assert_eq!(run(&e, "INDEX t_s 10.0"), "");
    assert_eq!(run(&e, "INDEX t_both 10"), "error\n");
}

#[test]
fn schema_with_views_triggers_and_internal_tables() {
    let mut b = DbBuilder::new(512);
    let root = b.table(&[(1, record(&[int(1)]))], 10);
    b.schema_row("table", "Zebra", "Zebra", root, Some("CREATE TABLE Zebra(a)"));
    b.schema_row("table", "apple", "apple", root, Some("CREATE TABLE apple(a)"));
    b.schema_row("table", "sqlite_sequence", "sqlite_sequence", root, Some("CREATE TABLE sqlite_sequence(name,seq)"));
    b.schema_row("view", "v", "v", 0, Some("CREATE VIEW v AS SELECT * FROM apple"));
    b.schema_row("trigger", "trg", "apple", 0, Some("CREATE TRIGGER trg AFTER INSERT ON apple BEGIN SELECT 1; END"));
    let e = Engine::from_bytes(b.finish()).unwrap();
    assert_eq!(run(&e, ".tables"), "Zebra\napple\n");
    assert_eq!(run(&e, "SELECT * FROM v"), "error\n");
    assert_eq!(run(&e, "COUNT trg"), "error\n");
    assert_eq!(run(&e, "COUNT sqlite_sequence"), "1\n");
    assert_eq!(
        run(&e, ".schema apple"),
        "CREATE TABLE apple(a);\nCREATE TRIGGER trg AFTER INSERT ON apple BEGIN SELECT 1; END;\n"
    );
    assert_eq!(run(&e, ".schema trg"), "");
    assert_eq!(run(&e, "SELECT a FROM ZEBRA"), "1\n");
}

#[test]
fn short_records_read_missing_columns_as_null() {
    let mut b = DbBuilder::new(512);
    let root = b.table(&[(1, record(&[int(5)])), (2, record(&[int(6), text("x")]))], 10);
    b.schema_row("table", "t", "t", root, Some("CREATE TABLE t(a, b TEXT, c REAL)"));
    let e = Engine::from_bytes(b.finish()).unwrap();
    assert_eq!(run(&e, "SELECT * FROM t"), "5\tNULL\tNULL\n6\tx\tNULL\n");
    assert_eq!(run(&e, "SELECT a FROM t WHERE b IS NULL"), "5\n");
}

#[test]
fn real_formatting_and_conversion() {
    let mut b = DbBuilder::new(512);
    let root = b.table(
        &[(1, record(&[int(3), Value::Real(1.0 / 3.0), Value::Real(1e300), Value::Real(-0.0), int(7)]))],
        10,
    );
    b.schema_row("table", "t", "t", root, Some("CREATE TABLE t(r REAL, s FLOAT, d DOUBLE, z NUMERIC, n NUMERIC)"));
    let e = Engine::from_bytes(b.finish()).unwrap();
    assert_eq!(run(&e, "SELECT * FROM t"), "3.0\t0.333333333333333\t1.0e+300\t0.0\t7\n");
}

#[test]
fn corrupt_files_report_errors_instead_of_panicking() {
    assert!(Engine::from_bytes(vec![0; 10]).is_err());
    let mut b = DbBuilder::new(512);
    b.schema_row("table", "t", "t", 99, Some("CREATE TABLE t(a)"));
    let e = Engine::from_bytes(b.finish()).unwrap();
    assert_eq!(run(&e, "SELECT * FROM t"), "error\n");
    assert_eq!(run(&e, "COUNT t"), "error\n");
}
