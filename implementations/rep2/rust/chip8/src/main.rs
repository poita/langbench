//! Command-line front end: reads a job on stdin, writes the final state to
//! stdout. See the crate README for the format.

use chip8::{render, Job, Machine};
use std::io::{self, Read, Write};
use std::process::ExitCode;

fn real_main() -> Result<(), Box<dyn std::error::Error>> {
    let mut text = String::new();
    io::stdin().read_to_string(&mut text)?;
    let job = Job::parse(&text)?;
    let mut machine = Machine::new();
    machine.load_rom(&job.rom)?;
    machine.run(job.cycles, &job.schedule);
    let mut out = io::stdout().lock();
    out.write_all(render::render(&machine).as_bytes())?;
    out.flush()?;
    Ok(())
}

fn main() -> ExitCode {
    match real_main() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("chip8: {e}");
            ExitCode::FAILURE
        }
    }
}
