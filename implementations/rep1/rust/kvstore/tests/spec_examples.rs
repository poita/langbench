//! The worked examples of the specification (§19.3, §21), run through the
//! public API.

use tessera::{Database, Value};

fn run(script: &str) -> (String, Database) {
    let mut db = Database::new();
    let out = db.run_script(script);
    (out, db)
}

#[allow(clippy::too_many_arguments)]
fn stat_block(n: usize, pages: u32, free: u32, head: u32, docs: u32, root: u32, height: u32, commits: u32, idx: u32, wal: u32) -> String {
    format!(
        "[{n}] ok stat\n  pages {pages}\n  free {free}\n  freehead {head}\n  docs {docs}\n  root {root}\n  height {height}\n  commits {commits}\n  indexes {idx}\n  wal {wal}\n"
    )
}

#[test]
fn small_script_from_section_19() {
    let (out, _) = run("put \"b\" 2\nput \"a\" {name:\"ada\",age:36}\nget \"a\"\nscan\nstat\n");
    let expected = "[1] ok put created\n[2] ok put created\n[3] ok get value\n  {\"age\":36,\"name\":\"ada\"}\n[4] ok scan 2\n  \"a\" = {\"age\":36,\"name\":\"ada\"}\n  \"b\" = 2\n"
        .to_string()
        + &stat_block(5, 2, 0, 0, 2, 2, 1, 2, 0, 4272);
    assert_eq!(out, expected);
}

#[test]
fn one_document_then_a_checkpoint() {
    let (out, db) = run("put \"a\" 1\ncheckpoint\nstat\n");
    assert_eq!(
        out,
        "[1] ok put created\n[2] ok checkpoint pages 2\n".to_string() + &stat_block(3, 2, 0, 0, 1, 2, 1, 1, 0, 32)
    );
    let main = db.main_bytes();
    assert_eq!(main.len(), 2048);
    // Page 1 is the header shown in the spec.
    assert_eq!(&main[0..48], &{
        let mut h = [0u8; 48];
        h[0..8].copy_from_slice(b"TESSERA1");
        h[8..16].copy_from_slice(&[0, 1, 4, 0, 0, 0, 0, 2]);
        h[27] = 2;
        h[31] = 1;
        h[39] = 1;
        h
    });
    // Page 2 is the leaf of §11.3.
    let leaf = &main[1024..2048];
    assert_eq!(&leaf[0..18], &[1, 0, 0, 1, 3, 0xea, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0xea]);
    assert_eq!(&leaf[1002..], &[0, 1, 0, 0, 0, 9, 0, 9, 0, 0, 0, 0, b'a', 3, 0, 0, 0, 0, 0, 0, 0, 1]);
    assert_eq!(db.wal_bytes().len(), 32);
    assert_eq!(&db.wal_bytes()[28..], &[0x51, 0xe7, 0x21, 0x53]);
}

#[test]
fn deleting_everything_then_reusing_the_page() {
    let (out, _) = run("put \"k1\" \"x\"\nput \"k2\" \"y\"\ndelete \"k1\"\ndelete \"k2\"\nstat\nput \"k3\" \"z\"\nstat\n");
    let expected = "[1] ok put created\n[2] ok put created\n[3] ok delete removed\n[4] ok delete removed\n".to_string()
        + &stat_block(5, 2, 1, 2, 0, 0, 0, 4, 0, 8512)
        + "[6] ok put created\n"
        + &stat_block(7, 2, 0, 0, 1, 2, 1, 5, 0, 10632);
    assert_eq!(out, expected);
}

#[test]
fn overflow_chain() {
    let (out, _) = run(
        "put \"big\" [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]\nstat\nget \"big\"\ndelete \"big\"\nstat\n",
    );
    let expected = "[1] ok put created\n".to_string()
        + &stat_block(2, 3, 0, 0, 1, 3, 1, 1, 0, 3200)
        + "[3] ok get value\n  [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]\n[4] ok delete removed\n"
        + &stat_block(5, 3, 2, 3, 0, 0, 0, 2, 0, 6368);
    assert_eq!(out, expected);
}

#[test]
fn rollback_and_commit() {
    let (out, db) = run("begin\nput \"a\" 1\nput \"b\" 2\nstat\nrollback\nstat\nbegin\nput \"a\" 1\ncommit\nstat\n");
    let expected = "[1] ok begin\n[2] ok put created\n[3] ok put created\n".to_string()
        + &stat_block(4, 2, 0, 0, 2, 2, 1, 0, 0, 32)
        + "[5] ok rollback\n"
        + &stat_block(6, 1, 0, 0, 0, 0, 0, 0, 0, 32)
        + "[7] ok begin\n[8] ok put created\n[9] ok commit 1 frames 2\n"
        + &stat_block(10, 2, 0, 0, 1, 2, 1, 1, 0, 2152);
    assert_eq!(out, expected);
    assert_eq!(db.main_bytes().len(), 1024);
}

#[test]
fn open_transaction_is_rolled_back_at_the_end() {
    let (_, db) = run("put \"a\" 1\nbegin\nput \"b\" 2\n");
    assert!(!db.in_transaction());
    assert_eq!(db.wal_bytes().len(), 2152);
}

#[test]
fn errors() {
    let script = "put \"a\" 1\nput \"a\" 2\nget \"zz\"\ndelete \"zz\"\nfrobnicate\nput \"a\"\nput \"a\" 007\nput \"a\" 9223372036854775808\nput \"a\" {x:1,x:2}\nput \"\\ud800\" 1\nput \"\" 1\ncommit\nrollback\nbegin\nbegin\ncheckpoint\n";
    let (out, db) = run(script);
    let expected = "[1] ok put created\n[2] ok put replaced\n[3] error not-found\n[4] error not-found\n[5] error unknown-command\n[6] error syntax\n[7] error syntax\n[8] error int-range\n[9] error dup-field\n[10] error bad-utf8\n[11] error bad-key\n[12] error no-txn\n[13] error no-txn\n[14] ok begin\n[15] error txn-active\n[16] error txn-active\n";
    assert_eq!(out, expected);
    assert_eq!(db.wal_bytes().len(), 32 + 2 * 2120);
}

#[test]
fn secondary_index_and_find() {
    let script = "put \"u1\" {name:\"ada\",age:36}\nput \"u2\" {name:\"bob\",age:29}\nput \"u3\" {name:\"cy\",age:36}\ncreate index age\nindexes\nfind age == 36\nfind age > 30\nfind age == 36 and name == \"cy\"\nfind not(age == 36)\nstat\n";
    let (out, _) = run(script);
    let expected = "[1] ok put created\n[2] ok put created\n[3] ok put created\n[4] ok create index age entries 3\n[5] ok indexes 1\n  0 age root 3 entries 3\n[6] ok find 2 plan index age\n  \"u1\" = {\"age\":36,\"name\":\"ada\"}\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n[7] ok find 2 plan index age\n  \"u1\" = {\"age\":36,\"name\":\"ada\"}\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n[8] ok find 1 plan index age\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n[9] ok find 1 plan scan\n  \"u2\" = {\"age\":29,\"name\":\"bob\"}\n".to_string()
        + &stat_block(10, 3, 0, 0, 3, 2, 1, 4, 1, 8512);
    assert_eq!(out, expected);
}

#[test]
fn scan_ranges() {
    let script = "put \"a\" 1\nput \"b\" 2\nput \"c\" 3\nput \"d\" 4\nscan\nscan from \"b\"\nscan to \"c\"\nscan from \"b\" to \"d\"\nscan limit 2\nscan reverse limit 2\nscan keys reverse\nscan from \"d\" to \"b\"\n";
    let (out, _) = run(script);
    let tail = "[5] ok scan 4\n  \"a\" = 1\n  \"b\" = 2\n  \"c\" = 3\n  \"d\" = 4\n[6] ok scan 3\n  \"b\" = 2\n  \"c\" = 3\n  \"d\" = 4\n[7] ok scan 2\n  \"a\" = 1\n  \"b\" = 2\n[8] ok scan 2\n  \"b\" = 2\n  \"c\" = 3\n[9] ok scan 2\n  \"a\" = 1\n  \"b\" = 2\n[10] ok scan 2\n  \"d\" = 4\n  \"c\" = 3\n[11] ok scan 4\n  \"d\"\n  \"c\"\n  \"b\"\n  \"a\"\n[12] ok scan 0\n";
    assert!(out.ends_with(tail), "{out}");
}

#[test]
fn update_and_unset() {
    let script = "put \"u1\" {name:\"ada\"}\nupdate \"u1\" age 36\nupdate \"u1\" addr.city \"oslo\"\nget \"u1\"\nunset \"u1\" addr.city\nget \"u1\"\nunset \"u1\" addr.zip\nunset \"u1\" name.first\nupdate \"u2\" age 1\n";
    let (out, _) = run(script);
    let expected = "[1] ok put created\n[2] ok update updated\n[3] ok update updated\n[4] ok get value\n  {\"addr\":{\"city\":\"oslo\"},\"age\":36,\"name\":\"ada\"}\n[5] ok unset updated\n[6] ok get value\n  {\"addr\":{},\"age\":36,\"name\":\"ada\"}\n[7] error no-field\n[8] error not-object\n[9] error not-found\n";
    assert_eq!(out, expected);
}

#[test]
fn checkpoint_and_drop_index() {
    let script = "put \"u1\" {age:1}\ncreate index age\nstat\ncheckpoint\nstat\ndrop index age\nstat\ndrop index age\n";
    let (out, db) = run(script);
    let expected = "[1] ok put created\n[2] ok create index age entries 1\n".to_string()
        + &stat_block(3, 3, 0, 0, 1, 2, 1, 2, 1, 4272)
        + "[4] ok checkpoint pages 3\n"
        + &stat_block(5, 3, 0, 0, 1, 2, 1, 2, 1, 32)
        + "[6] ok drop index age pages 1\n"
        + &stat_block(7, 3, 1, 3, 1, 2, 1, 3, 0, 2152)
        + "[8] error index-missing\n";
    assert_eq!(out, expected);
    // main.tdb still shows the index (slot 0 live); the log holds the newer state.
    assert_eq!(db.main_bytes().len(), 3072);
    assert_eq!(db.main_bytes()[128], 1);
}

const DOC20: &str = "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]";

#[test]
fn split_borrow_and_merge() {
    let mut script = String::new();
    for i in 1..=6 {
        script += &format!("put \"k{i}\" {DOC20}\n");
    }
    script += "stat\nscan keys\ndelete \"k1\"\ndelete \"k2\"\ndelete \"k3\"\nstat\nscan keys\n";
    let (out, _) = run(&script);
    let keys = |ks: &[&str]| {
        let mut s = String::new();
        for k in ks {
            s += &format!("  \"{k}\"\n");
        }
        s
    };
    let expected = "[1] ok put created\n[2] ok put created\n[3] ok put created\n[4] ok put created\n[5] ok put created\n[6] ok put created\n".to_string()
        + &stat_block(7, 4, 0, 0, 6, 4, 2, 6, 0, 14848)
        + "[8] ok scan 6\n"
        + &keys(&["k1", "k2", "k3", "k4", "k5", "k6"])
        + "[9] ok delete removed\n[10] ok delete removed\n[11] ok delete removed\n"
        + &stat_block(12, 4, 2, 4, 3, 2, 1, 9, 0, 25400)
        + "[13] ok scan 3\n"
        + &keys(&["k4", "k5", "k6"]);
    assert_eq!(out, expected);
}

#[test]
fn thin_page_left_by_a_replace() {
    let mut script = String::new();
    for i in 1..=6 {
        script += &format!("put \"k{i}\" {DOC20}\n");
    }
    script += "put \"k1\" 1\nput \"k2\" 2\nstat\ndelete \"k3\"\nstat\nscan keys\n";
    let (out, _) = run(&script);
    assert!(out.contains(&stat_block(9, 4, 0, 0, 6, 4, 2, 8, 0, 19088)), "{out}");
    assert!(out.contains(&stat_block(11, 4, 0, 0, 5, 4, 2, 9, 0, 23304)), "{out}");
}

#[test]
fn library_api() {
    let mut db = Database::new();
    db.put(b"a", &Value::Int(1)).unwrap();
    assert_eq!(db.get(b"a"), Ok(Value::Int(1)));
    assert_eq!(db.get(b"zz"), Err(tessera::Error::NotFound));
    assert_eq!(db.delete(b"a"), Ok(()));
    assert_eq!(db.delete(b"a"), Err(tessera::Error::NotFound));
}
