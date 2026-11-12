//! Command-line front end.
//!
//! Reads all of stdin: the first line is the filter, the rest is one JSON
//! document. Every result is printed as one line of compact JSON. If an
//! uncaught error occurs, the results so far are printed followed by a line
//! `error`; the exit status is still 0.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use jq_subset::{Filter, Value};

fn run() -> Result<(), String> {
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input).map_err(|e| format!("cannot read stdin: {e}"))?;
    let split = input.iter().position(|&b| b == b'\n').unwrap_or(input.len());
    let (filter_bytes, doc_bytes) = input.split_at(split);

    let filter_src = std::str::from_utf8(filter_bytes).map_err(|_| "filter is not valid UTF-8".to_string())?;
    let doc_src = std::str::from_utf8(doc_bytes).map_err(|_| "document is not valid UTF-8".to_string())?;
    let filter = Filter::parse(filter_src).map_err(|e| e.to_string())?;
    let doc = Value::parse_json(doc_src).map_err(|e| e.to_string())?;

    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(1 << 16, stdout.lock());
    let mut line = String::new();
    let mut write_failed = false;
    let result = filter.run(&doc, |v| {
        if write_failed {
            return;
        }
        line.clear();
        v.write_json(&mut line);
        line.push('\n');
        write_failed = out.write_all(line.as_bytes()).is_err();
    });
    if write_failed {
        return Ok(());
    }
    if let Err(e) = result {
        eprintln!("jq: error: {e}");
        let _ = out.write_all(b"error\n");
    }
    let _ = out.flush();
    Ok(())
}

fn main() -> ExitCode {
    // Evaluation is recursive; give it plenty of stack.
    let handle = std::thread::Builder::new().stack_size(512 << 20).spawn(run);
    match handle.map(|h| h.join()) {
        Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
        Ok(Ok(Err(msg))) => {
            eprintln!("jq: {msg}");
            ExitCode::from(2)
        }
        _ => ExitCode::from(2),
    }
}
