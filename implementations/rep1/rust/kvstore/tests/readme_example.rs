//! Keeps the library example of README.md compiling and correct.

use tessera::{parse_command, Command, Database, Path, ScanOptions, Value};

#[test]
fn readme_example() -> tessera::Result<()> {
    let mut db = Database::new();

    // Typed API.
    let Command::Put { value, .. } = parse_command(r#"put "u1" {name:"ada", age:36}"#)? else {
        unreachable!()
    };
    db.put(b"u1", &value)?;
    db.create_index(&Path::parse("age")?)?;
    db.begin()?;
    db.update(b"u1", &Path::parse("age")?, Value::Int(37))?;
    db.commit()?;
    assert_eq!(db.get(b"u1")?.render(), r#"{"age":37,"name":"ada"}"#);
    let rows = db.scan(&ScanOptions { keys_only: true, ..Default::default() })?;
    assert_eq!(rows.len(), 1);

    // Command language: the text returned is the content of results.txt.
    let results = db.run_script("get \"u1\"\nstat\n");
    assert!(results.starts_with("[1] ok get value"));

    // The two files, ready to be written anywhere and reopened later.
    let (main, wal) = (db.main_bytes().to_vec(), db.wal_bytes().to_vec());
    let reopened = Database::open(Some(&main), Some(&wal))?;
    assert_eq!(reopened.get(b"u1")?, db.get(b"u1")?);
    Ok(())
}
