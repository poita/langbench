//! Command-line front end: reads the filter (first line) and a JSON document (the rest) from
//! stdin and prints each result as one line of compact JSON.
//!
//! If evaluation fails, results produced before the error are printed, then a line `error`.

use jqlite::{Filter, Value};
use std::io::{self, Read, Write};
use std::process::ExitCode;

fn run() -> Result<(), String> {
    let mut raw = Vec::new();
    io::stdin().read_to_end(&mut raw).map_err(|e| format!("cannot read stdin: {e}"))?;
    let text = String::from_utf8_lossy(&raw);
    let (filter_src, doc_src) = match text.find('\n') {
        Some(i) => (&text[..i], &text[i + 1..]),
        None => (&text[..], ""),
    };
    let filter = Filter::parse(filter_src.trim_end_matches('\r')).map_err(|e| e.to_string())?;
    let doc = Value::from_json(doc_src).map_err(|e| e.to_string())?;

    let stdout = io::stdout();
    let mut w = io::BufWriter::with_capacity(1 << 16, stdout.lock());
    let mut line = String::new();
    let mut io_err = None;
    let result = filter.run(&doc, |v| {
        line.clear();
        jqlite::json::write_value(&v, &mut line);
        line.push('\n');
        if let Err(e) = w.write_all(line.as_bytes()) {
            io_err.get_or_insert(e);
        }
    });
    if result.is_err() {
        let _ = w.write_all(b"error\n");
    }
    w.flush().map_err(|e| format!("cannot write stdout: {e}"))?;
    match io_err {
        Some(e) => Err(format!("cannot write stdout: {e}")),
        None => Ok(()),
    }
}

fn main() -> ExitCode {
    // Evaluation recurses with the nesting of the filter and the document; give it room.
    let handle = std::thread::Builder::new().stack_size(512 << 20).spawn(run);
    match handle.map(|h| h.join()) {
        Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
        Ok(Ok(Err(msg))) => {
            eprintln!("jqlite: {msg}");
            ExitCode::from(2)
        }
        _ => {
            eprintln!("jqlite: internal error");
            ExitCode::from(3)
        }
    }
}
