//! Command-line front end: reads a request on stdin and prints one
//! `valid`/`invalid` line per test instance.
//!
//! The request is a JSON object with `schema`, `tests` (each with a `data`
//! member) and an optional `remotes` object mapping URIs to schema documents.

use jsonschema::{json, Json, Schema};
use std::io::{Read, Write};
use std::process::ExitCode;

/// Validation recurses deeply on deeply nested schemas, so run on a thread
/// with a generous stack.
const STACK_BYTES: usize = 1 << 30;

fn run(input: &str) -> Result<String, String> {
    let request = json::parse(input).map_err(|e| e.to_string())?;
    let request = request.as_object().ok_or("input must be a JSON object")?;
    let schema_doc = request.get("schema").ok_or("missing \"schema\" member")?;
    let tests = request
        .get("tests")
        .and_then(Json::as_array)
        .ok_or("missing \"tests\" array")?;

    let mut builder = Schema::builder();
    if let Some(remotes) = request.get("remotes").and_then(Json::as_object) {
        for (uri, doc) in remotes.iter() {
            builder = builder.remote(uri, doc);
        }
    }
    let schema = builder.build(schema_doc).map_err(|e| e.to_string())?;

    let mut out = String::new();
    for (i, test) in tests.iter().enumerate() {
        let data = test
            .as_object()
            .and_then(|t| t.get("data"))
            .ok_or_else(|| format!("test {i} has no \"data\" member"))?;
        out.push_str(if schema.is_valid(data) { "valid\n" } else { "invalid\n" });
    }
    Ok(out)
}

fn main() -> ExitCode {
    let worker = std::thread::Builder::new()
        .stack_size(STACK_BYTES)
        .spawn(|| {
            let mut input = String::new();
            if let Err(e) = std::io::stdin().read_to_string(&mut input) {
                eprintln!("error: cannot read stdin: {e}");
                return ExitCode::from(2);
            }
            match run(&input) {
                Ok(output) => {
                    let mut stdout = std::io::stdout().lock();
                    if stdout.write_all(output.as_bytes()).and_then(|()| stdout.flush()).is_err() {
                        return ExitCode::from(1);
                    }
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(1)
                }
            }
        })
        .expect("failed to spawn worker thread");
    worker.join().unwrap_or(ExitCode::from(101))
}
