//! Library-level tests built from the worked examples in the specification.

use chip8::{render, Job, Machine};

fn run(input: &str) -> String {
    let job = Job::parse(input).expect("valid input");
    let mut m = Machine::new();
    m.load_rom(&job.rom).expect("rom fits");
    m.run(job.cycles, &job.schedule);
    render::render(&m)
}

fn blank_rows(n: usize) -> String {
    format!("{}\n", ".".repeat(64)).repeat(n)
}

#[test]
fn example1_arithmetic_and_self_loop() {
    let out = run("60ff7001610180141208\n6\n");
    let expected = format!(
        "{}PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n",
        blank_rows(32)
    );
    assert_eq!(out, expected);
}

#[test]
fn example2_wraparound_draw() {
    let out = run("6a3e6b1e6000f029dab5dab5\n5\n");
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 34);
    let edge = |l: &str, left: &str, right: &str| {
        format!("{left}{}{right}", ".".repeat(64 - left.len() - right.len())) == l
    };
    assert!(edge(lines[0], ".#", "#."));
    assert!(edge(lines[1], ".#", "#."));
    assert!(edge(lines[2], "##", "##"));
    assert!(edge(lines[30], "##", "##"));
    assert!(edge(lines[31], ".#", "#."));
    assert_eq!(lines[32], "PC=020a I=0050 SP=0 DT=00 ST=00");
    assert_eq!(lines[33], "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00");
}

#[test]
fn example2_second_draw_erases_and_sets_collision() {
    let out = run("6a3e6b1e6000f029dab5dab5\n6\n");
    assert!(out.starts_with(&blank_rows(32)));
    assert!(out.ends_with(
        "PC=020c I=0050 SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01\n"
    ));
}

#[test]
fn example3_rng_timers_and_keys() {
    let out = run("c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n");
    let expected = format!(
        "{}PC=021e I=0000 SP=0 DT=07 ST=00\nV=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n",
        blank_rows(32)
    );
    assert_eq!(out, expected);
}

#[test]
fn zero_cycles_runs_nothing() {
    let out = run("60ff\n0\n");
    assert!(out.contains("PC=0200 I=0000 SP=0 DT=00 ST=00\n"));
}

#[test]
fn key_event_at_cycle_n_has_no_effect() {
    // FX0A would store a key, but the event only arrives at cycle N = 1.
    let out = run("f00a\n1\n1:0001\n");
    assert!(out.contains("PC=0200 "));
    assert!(out.ends_with("V=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"));
}

#[test]
fn memory_access_wraps_at_12_bits() {
    // V0 = 0xAA, V1 = 0xBB, I = 0xFFF, store V0..V1 -> mem[0xFFF], mem[0x000].
    let job = Job::parse("60aa61bbafffF155\n4\n".to_lowercase().as_str()).unwrap();
    let mut m = Machine::new();
    m.load_rom(&job.rom).unwrap();
    m.run(job.cycles, &job.schedule);
    assert_eq!(m.memory()[0xFFF], 0xAA);
    assert_eq!(m.memory()[0x000], 0xBB);
    assert_eq!(m.index(), 0xFFF);
}
