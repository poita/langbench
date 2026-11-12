//! Runs the shared problem corpus (`../problems/jsonschema/tests/*.in`) when
//! it is present next to this project; silently passes otherwise.

use jsonschema::{json, Json, Schema};
use std::fs;
use std::path::PathBuf;

fn run(input: &str) -> String {
    let req = json::parse(input).unwrap();
    let req = req.as_object().unwrap();
    let mut b = Schema::builder();
    if let Some(r) = req.get("remotes").and_then(Json::as_object) {
        for (uri, doc) in r.iter() {
            b = b.remote(uri, doc);
        }
    }
    let schema = b.build(req.get("schema").unwrap()).unwrap();
    let mut out = String::new();
    for t in req.get("tests").and_then(Json::as_array).unwrap() {
        let data = t.as_object().unwrap().get("data").unwrap();
        out.push_str(if schema.is_valid(data) { "valid\n" } else { "invalid\n" });
    }
    out
}

#[test]
fn corpus_matches_expected_output() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../problems/jsonschema/tests");
    let Ok(entries) = fs::read_dir(&dir) else {
        eprintln!("corpus not found at {}; skipping", dir.display());
        return;
    };
    let mut inputs: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "in"))
        .collect();
    inputs.sort();
    // Deep schemas need more stack than a default test thread has.
    let handle = std::thread::Builder::new()
        .stack_size(256 << 20)
        .spawn(move || {
            let mut failures = Vec::new();
            for path in &inputs {
                let input = fs::read_to_string(path).unwrap();
                let expected = fs::read_to_string(path.with_extension("out")).unwrap();
                let got = run(&input);
                let norm = |s: &str| s.lines().map(str::trim_end).collect::<Vec<_>>().join("\n");
                if norm(&got) != norm(&expected) {
                    failures.push(path.file_name().unwrap().to_string_lossy().into_owned());
                }
            }
            failures
        })
        .unwrap();
    let failures = handle.join().unwrap();
    assert!(failures.is_empty(), "failing corpus cases: {failures:?}");
}
