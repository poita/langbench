//! Randomised comparison of the engine against a plain `BTreeMap` model,
//! including secondary indexes, transactions, checkpoints and reopening from
//! the two files.

use std::collections::BTreeMap;

use tessera::{parse_command, Command, Database, Error, ScanOptions, Value};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn random_doc(rng: &mut Rng) -> String {
    let age = match rng.below(6) {
        0 => "null".to_string(),
        1 => "true".to_string(),
        2 => format!("\"s{}\"", rng.below(20)),
        3 => "[1]".to_string(),
        _ => (rng.below(40) as i64 - 10).to_string(),
    };
    let pad = "z".repeat(rng.below(300) as usize * (rng.below(3) == 0) as usize);
    if rng.below(8) == 0 {
        format!("{{name:\"n\",pad:\"{pad}\"}}")
    } else {
        format!("{{age:{age},pad:\"{pad}\",inner:{{v:{}}}}}", rng.below(5))
    }
}

fn parse_doc(src: &str) -> Value {
    match parse_command(&format!("put \"k\" {src}")).unwrap() {
        Command::Put { value, .. } => value,
        _ => unreachable!(),
    }
}

fn key(rng: &mut Rng) -> String {
    format!("key{:03}", rng.below(150))
}

fn check_against_model(db: &Database, model: &BTreeMap<String, Value>) {
    let rows = db.scan(&ScanOptions::default()).unwrap();
    let got: Vec<(String, Value)> =
        rows.into_iter().map(|(k, v)| (String::from_utf8(k).unwrap(), v.unwrap())).collect();
    let want: Vec<(String, Value)> = model.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    assert_eq!(got, want);
    let rev = db.scan(&ScanOptions { reverse: true, limit: Some(7), keys_only: true, ..Default::default() }).unwrap();
    let want_rev: Vec<Vec<u8>> = model.keys().rev().take(7).map(|k| k.as_bytes().to_vec()).collect();
    assert_eq!(rev.into_iter().map(|(k, _)| k).collect::<Vec<_>>(), want_rev);
    assert_eq!(db.stat().unwrap().docs as usize, model.len());
}

fn check_finds(db: &Database, model: &BTreeMap<String, Value>) {
    for q in [
        "age == 5",
        "age < 3",
        "age <= 3",
        "age > 20",
        "age >= 20",
        "age == null",
        "age <= null",
        "age > false",
        "age >= \"s5\"",
        "age < \"s7\"",
        "age == \"s3\" or age == 4",
        "age != 5",
        "inner.v == 2 and age >= 0",
        "exists name",
        "missing age",
    ] {
        let cmd = parse_command(&format!("find {q}")).unwrap();
        let Command::Find { pred, .. } = cmd else { unreachable!() };
        let got = db.find(&pred, None).unwrap();
        let want: Vec<(Vec<u8>, Value)> = model
            .iter()
            .filter(|(_, v)| pred.eval(v))
            .map(|(k, v)| (k.as_bytes().to_vec(), v.clone()))
            .collect();
        assert_eq!(got.rows, want, "query {q} plan {:?}", got.plan);
        let limited = db.find(&pred, Some(3)).unwrap();
        assert_eq!(limited.rows, want.iter().take(3).cloned().collect::<Vec<_>>());
    }
}

fn run_model(seed: u64, steps: usize, with_indexes: bool) {
    let mut rng = Rng(seed);
    let mut db = Database::new();
    let mut model: BTreeMap<String, Value> = BTreeMap::new();
    let mut txn_snapshot: Option<BTreeMap<String, Value>> = None;
    if with_indexes {
        db.execute_line("create index age").unwrap();
        db.execute_line("create index inner.v").unwrap();
    }
    for step in 0..steps {
        match rng.below(20) {
            0..=8 => {
                let k = key(&mut rng);
                let src = random_doc(&mut rng);
                let r = db.execute_line(&format!("put \"{k}\" {src}"));
                assert!(r.is_ok(), "{r:?}");
                model.insert(k, parse_doc(&src));
            }
            9..=11 => {
                let k = key(&mut rng);
                let r = db.execute_line(&format!("delete \"{k}\""));
                assert_eq!(r.is_ok(), model.remove(&k).is_some());
            }
            12 | 13 => {
                let k = key(&mut rng);
                let v = rng.below(30);
                let r = db.execute_line(&format!("update \"{k}\" age {v}"));
                match model.get_mut(&k) {
                    Some(Value::Object(f)) => {
                        assert!(r.is_ok());
                        f.insert("age".into(), Value::Int(v as i64));
                    }
                    _ => assert!(r.is_err()),
                }
            }
            14 => {
                let k = key(&mut rng);
                let r = db.execute_line(&format!("unset \"{k}\" age"));
                match model.get_mut(&k) {
                    Some(Value::Object(f)) if f.contains_key("age") => {
                        assert!(r.is_ok());
                        f.remove("age");
                    }
                    Some(_) => assert!(matches!(r, Err(Error::NoField) | Err(Error::NotObject))),
                    None => assert_eq!(r, Err(Error::NotFound)),
                }
            }
            15 => {
                if txn_snapshot.is_none() {
                    db.execute_line("begin").unwrap();
                    txn_snapshot = Some(model.clone());
                } else if rng.below(2) == 0 {
                    db.execute_line("commit").unwrap();
                    txn_snapshot = None;
                } else {
                    db.execute_line("rollback").unwrap();
                    model = txn_snapshot.take().unwrap();
                }
            }
            16 => {
                let r = db.execute_line("checkpoint");
                assert_eq!(r.is_ok(), txn_snapshot.is_none());
            }
            17 if txn_snapshot.is_none() => {
                // Reopen from the two files.
                let (main, log) = (db.main_bytes().to_vec(), db.wal_bytes().to_vec());
                db = Database::open(Some(&main), Some(&log)).unwrap();
                assert_eq!(db.main_bytes(), &main[..]);
                assert_eq!(db.wal_bytes(), &log[..]);
            }
            _ => {}
        }
        if step % 40 == 0 {
            check_against_model(&db, &model);
            check_finds(&db, &model);
        }
    }
    check_against_model(&db, &model);
    check_finds(&db, &model);
}

#[test]
fn random_workload_without_indexes() {
    run_model(0x1234_5678_9abc_def1, 1500, false);
}

#[test]
fn random_workload_with_indexes() {
    run_model(0x0fed_cba9_8765_4321, 1500, true);
}

#[test]
fn index_created_late_matches_index_maintained() {
    // An index built from existing documents and one maintained across the
    // same writes must hold the same entries.
    let mut rng = Rng(99);
    let mut a = Database::new();
    let mut script = String::new();
    for _ in 0..300 {
        let k = key(&mut rng);
        script += &format!("put \"{k}\" {}\n", random_doc(&mut rng));
        if rng.below(4) == 0 {
            script += &format!("delete \"{}\"\n", key(&mut rng));
        }
    }
    a.run_script(&script);
    let mut b = Database::open(Some(a.main_bytes()), Some(a.wal_bytes())).unwrap();
    a.execute_line("create index age").unwrap();
    b.execute_line("create index age").unwrap();
    assert_eq!(a.indexes(), b.indexes());
    assert_eq!(a.main_bytes(), b.main_bytes());
    assert_eq!(a.wal_bytes(), b.wal_bytes());
}
