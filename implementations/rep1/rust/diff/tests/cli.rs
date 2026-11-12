//! End-to-end tests: run the binary and check its output, plus randomized
//! checks of the library against a dynamic-programming LCS.

use std::io::Write;
use std::process::{Command, Stdio};

use linediff::{cost, diff, patch, Edit, ScriptLine, Tag};

fn run_cli(input: &str) -> (bool, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_linediff"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    (out.status.success(), String::from_utf8(out.stdout).unwrap())
}

#[test]
fn spec_example_1_has_cost_5() {
    let input = "diff\n7\na\nb\nc\na\nb\nb\na\n6\nc\nb\na\nb\na\nc\n";
    let (ok, out) = run_cli(input);
    assert!(ok);
    let mut lines = out.lines();
    let k: usize = lines.next().unwrap().parse().unwrap();
    let script: Vec<&str> = lines.collect();
    assert_eq!(script.len(), k);
    let changes = script.iter().filter(|l| !l.starts_with(' ')).count();
    assert_eq!(changes, 5);
}

#[test]
fn spec_example_3_patch() {
    let input = "patch\n5\na\nb\nc\nd\ne\n8\n a\n-b\n+B\n c\n+c2\n-d\n e\n+f\n";
    let (ok, out) = run_cli(input);
    assert!(ok);
    assert_eq!(out, "6\na\nB\nc\nc2\ne\nf\n");
}

#[test]
fn whitespace_is_preserved() {
    let input = "diff\n1\nx \n1\n x\n";
    let (ok, out) = run_cli(input);
    assert!(ok);
    assert_eq!(out, "2\n-x \n+ x\n");
}

#[test]
fn empty_patch_result() {
    let (ok, out) = run_cli("patch\n1\na\n1\n-a\n");
    assert!(ok);
    assert_eq!(out, "0\n");
}

#[test]
fn malformed_input_fails() {
    let (ok, _) = run_cli("diff\n3\na\n");
    assert!(!ok);
}

// ---- randomized library tests -------------------------------------------

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

fn lcs(a: &[u32], b: &[u32]) -> usize {
    let mut prev = vec![0usize; b.len() + 1];
    for &x in a {
        let mut cur = vec![0usize; b.len() + 1];
        for (j, &y) in b.iter().enumerate() {
            cur[j + 1] = if x == y { prev[j] + 1 } else { prev[j + 1].max(cur[j]) };
        }
        prev = cur;
    }
    prev[b.len()]
}

#[test]
fn random_pairs_are_minimal_and_roundtrip() {
    let mut rng = Rng(0x9E3779B97F4A7C15);
    for _ in 0..300 {
        let alphabet = 1 + rng.below(8);
        let n = rng.below(120) as usize;
        let m = rng.below(120) as usize;
        let a: Vec<u32> = (0..n).map(|_| rng.below(alphabet) as u32).collect();
        // Half of the time derive b from a by edits, to get long common runs.
        let b: Vec<u32> = if rng.below(2) == 0 {
            (0..m).map(|_| rng.below(alphabet) as u32).collect()
        } else {
            let mut b = a.clone();
            for _ in 0..rng.below(10) {
                let pos = rng.below(b.len() as u64 + 1) as usize;
                if rng.below(2) == 0 && pos < b.len() {
                    b.remove(pos);
                } else {
                    b.insert(pos, rng.below(alphabet) as u32);
                }
            }
            b
        };
        let edits = diff(&a, &b);
        assert_eq!(cost(&edits), a.len() + b.len() - 2 * lcs(&a, &b));
        let script: Vec<ScriptLine<u32>> = edits
            .iter()
            .map(|e| match *e {
                Edit::Keep { a: i, .. } => ScriptLine { tag: Tag::Keep, text: a[i] },
                Edit::Delete { a: i } => ScriptLine { tag: Tag::Delete, text: a[i] },
                Edit::Insert { b: j } => ScriptLine { tag: Tag::Insert, text: b[j] },
            })
            .collect();
        assert_eq!(patch(&a, &script).unwrap(), b);
    }
}

#[test]
fn disjoint_inputs_worst_case() {
    let a: Vec<u32> = (0..1500).collect();
    let b: Vec<u32> = (1500..3000).collect();
    assert_eq!(cost(&diff(&a, &b)), 3000);
}
