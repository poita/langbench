#![doc = include_str!("../README.md")]
#![warn(missing_docs)]

pub mod ast;
pub mod builtins;
pub mod diag;
pub mod exhaust;
pub mod infer;
pub mod ir;
pub mod lexer;
pub mod parser;
pub mod program;
pub mod resolve;
pub mod source;
pub mod types;
pub mod check;
pub mod bytecode;
pub mod compile;
pub mod numfmt;
pub mod stdlib;
pub mod value;
pub mod vm;

use diag::Diag;

/// The outcome of compiling a program: either a runnable program or a
/// diagnostic.
pub use bytecode::CompiledProgram;

/// Compiles a module stream into a runnable program.
///
/// # Errors
/// The single diagnostic the program is rejected with.
pub fn compile(input: &str) -> Result<CompiledProgram, Diag> {
    let modules = source::split_modules(input)?;
    let mut tokens = Vec::with_capacity(modules.len());
    for m in &modules {
        tokens.push(lexer::lex(&m.text)?);
    }
    let mut asts = Vec::with_capacity(modules.len());
    for (m, toks) in modules.iter().zip(tokens) {
        let eof = diag::Pos::new(m.num_lines, m.last_line_len + 1);
        asts.push(parser::parse_module(toks, eof)?);
    }
    let names: Vec<String> = modules.iter().map(|m| m.name.clone()).collect();
    let analysis = resolve::analyze(names, asts)?;
    let funcs = check::check_program(&analysis)?;
    Ok(compile::compile_program(&analysis.prog, &funcs))
}

/// Runs a compiled program, returning everything it wrote to stdout
/// (including a final `panic: ...` line if it panicked).
pub fn run(program: &CompiledProgram) -> Vec<u8> {
    let mut machine = vm::Vm::new(program);
    machine.run_main();
    machine.out
}

fn run_source_bytes(input: &str) -> Vec<u8> {
    match compile(input) {
        Ok(p) => {
            let mut machine = vm::Vm::new(&p);
            machine.run_main();
            let out = std::mem::take(&mut machine.out);
            // The process is about to end: skip tearing down large heaps.
            std::mem::forget(machine);
            std::mem::forget(p);
            out
        }
        Err(d) => format!("{}\n", d).into_bytes(),
    }
}

/// Compiles and runs a module stream, returning the complete stdout text.
///
/// A rejected program yields the single diagnostic line; a panic yields the
/// program's output followed by the panic line. The work runs on a thread
/// with a large stack so that deeply nested programs and data cannot
/// overflow the host stack.
pub fn run_source(input: &str) -> String {
    String::from_utf8_lossy(&run_source_to_bytes(input)).into_owned()
}

/// Like [`run_source`] but returns raw bytes.
pub fn run_source_to_bytes(input: &str) -> Vec<u8> {
    let owned = input.to_string();
    std::thread::Builder::new()
        .stack_size(512 << 20)
        .spawn(move || run_source_bytes(&owned))
        .expect("spawn interpreter thread")
        .join()
        .unwrap_or_else(|_| b"panic: internal error\n".to_vec())
}
