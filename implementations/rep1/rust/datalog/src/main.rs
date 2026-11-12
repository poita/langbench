//! Command-line front end: reads a Datalog program on stdin and prints the
//! answers to its queries on stdout, or `error` if the program is unsafe,
//! unstratifiable or malformed. The exit code is 0 in both cases.

use std::io::{Read, Write};

fn main() {
    let mut source = Vec::new();
    if let Err(e) = std::io::stdin().read_to_end(&mut source) {
        eprintln!("cannot read stdin: {e}");
        println!("error");
        return;
    }
    let source = String::from_utf8_lossy(&source);
    let text = match datalog::run(&source) {
        Ok(out) => out,
        Err(e) => {
            eprintln!("{e}");
            "error\n".to_string()
        }
    };
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(text.as_bytes());
    let _ = stdout.flush();
}
