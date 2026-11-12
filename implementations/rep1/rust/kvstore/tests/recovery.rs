//! Recovery from logs cut at arbitrary offsets and from damaged logs
//! (spec §16).

use tessera::Database;

const SCRIPT: &str = "put \"a\" 1\nput \"b\" {x:\"y\"}\ncreate index x\nput \"c\" [1,2,3]\ndelete \"a\"\n";

fn full_run() -> (Database, Vec<usize>) {
    let mut db = Database::new();
    let mut boundaries = vec![32];
    for line in SCRIPT.lines() {
        db.execute_line(line).unwrap();
        boundaries.push(db.wal_bytes().len());
    }
    (db, boundaries)
}

fn scan_text(db: &mut Database) -> String {
    db.run_script("scan\nstat\n")
}

#[test]
fn every_cut_keeps_exactly_the_committed_prefix() {
    let (db, boundaries) = full_run();
    let log = db.wal_bytes().to_vec();
    let main = db.main_bytes().to_vec();
    // Expected visible state after k commits: replay the first k lines.
    let expected: Vec<String> = (0..boundaries.len())
        .map(|k| {
            let mut d = Database::new();
            for line in SCRIPT.lines().take(k) {
                d.execute_line(line).unwrap();
            }
            scan_text(&mut d)
        })
        .collect();
    for cut in 0..=log.len() {
        let mut d = Database::open(Some(&main), Some(&log[..cut])).unwrap();
        let k = boundaries.iter().rposition(|&b| b <= cut);
        match k {
            Some(k) => {
                assert_eq!(d.wal_bytes(), &log[..boundaries[k]], "cut {cut}");
                assert_eq!(scan_text(&mut d), expected[k], "cut {cut}");
            }
            None => {
                // Header damaged or missing: the whole log is discarded.
                assert_eq!(d.wal_bytes().len(), 32, "cut {cut}");
                assert_eq!(scan_text(&mut d), expected[0], "cut {cut}");
            }
        }
        assert_eq!(d.main_bytes(), &main[..]);
    }
}

#[test]
fn damaged_headers_discard_the_log() {
    let (db, _) = full_run();
    let log = db.wal_bytes().to_vec();
    let baseline = Database::new().run_script("stat\n");
    for pos in [0, 8, 10, 12, 27, 28, 31] {
        let mut bad = log.clone();
        bad[pos] ^= 1;
        let mut d = Database::open(None, Some(&bad)).unwrap();
        assert_eq!(d.wal_bytes().len(), 32);
        assert_eq!(d.run_script("stat\n"), baseline, "byte {pos}");
    }
}

#[test]
fn trailing_garbage_is_trimmed_and_corruption_stops_the_scan() {
    let (db, boundaries) = full_run();
    let mut log = db.wal_bytes().to_vec();
    let good = log.len();
    log.extend_from_slice(&[0u8; 100]);
    let d = Database::open(None, Some(&log)).unwrap();
    assert_eq!(d.wal_bytes().len(), good);
    // Flip a payload byte of the third transaction: the scan stops before it.
    let mut log = db.wal_bytes().to_vec();
    log[boundaries[2] + 24 + 5] ^= 0xff;
    let d = Database::open(None, Some(&log)).unwrap();
    assert_eq!(d.wal_bytes().len(), boundaries[2]);
}

#[test]
fn main_file_is_not_modified_by_recovery_and_checkpoint_applies_the_log() {
    let (db, _) = full_run();
    let log = db.wal_bytes().to_vec();
    let mut d = Database::open(None, Some(&log)).unwrap();
    assert_eq!(d.main_bytes().len(), 1024);
    let before = scan_text(&mut d);
    let out = d.run_script("checkpoint\n");
    assert!(out.starts_with("[1] ok checkpoint pages "));
    assert_eq!(d.wal_bytes().len(), 32);
    let main = d.main_bytes().to_vec();
    let mut again = Database::open(Some(&main), None).unwrap();
    // Same content; only the log size reported by `stat` differs.
    let strip = |s: String| s.lines().filter(|l| !l.contains("wal ")).collect::<Vec<_>>().join("\n");
    assert_eq!(strip(scan_text(&mut again)), strip(before));
}
