//! Helpers shared by the integration tests.

/// Wraps a program body as the single `main` module.
pub fn main_module(body: &str) -> String {
    format!("@module main\n{}\n", body)
}

/// Runs a full module stream.
pub fn run(src: &str) -> String {
    langvm::run_source(src)
}

/// Runs `body` as module `main` and returns stdout.
pub fn run_main(body: &str) -> String {
    run(&main_module(body))
}
