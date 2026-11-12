//! Integration tests: worked examples from the specification and
//! instruction-level behaviour, driven through the public API.

use chip8::{run_text, Input, KeySchedule, Machine};

fn blank_rows(n: usize) -> String {
    format!("{}\n", ".".repeat(64)).repeat(n)
}

fn run(rom_hex: &str, cycles: u64, keys: &str) -> Machine {
    let input = Input::parse(&format!("{rom_hex}\n{cycles}\n{keys}\n")).unwrap();
    let mut m = Machine::new(&input.rom).unwrap();
    m.run(input.cycles, &input.keys);
    m
}

#[test]
fn example1_self_loop() {
    let out = run_text("60ff7001610180141208\n6\n").unwrap();
    let want = format!(
        "{}PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n",
        blank_rows(32)
    );
    assert_eq!(out, want);
}

#[test]
fn example2_wrap_and_collision() {
    let out = run_text("6a3e6b1e6000f029dab5dab5\n5").unwrap();
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 34);
    assert_eq!(lines[0], ".#............................................................#.");
    assert_eq!(lines[2], "##............................................................##");
    assert_eq!(lines[30], "##............................................................##");
    assert_eq!(lines[31], ".#............................................................#.");
    assert_eq!(lines[32], "PC=020a I=0050 SP=0 DT=00 ST=00");
    assert_eq!(lines[33], "V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00");

    let out = run_text("6a3e6b1e6000f029dab5dab5\n6").unwrap();
    assert!(out.starts_with(&blank_rows(32)));
    assert!(out.contains("PC=020c"));
    assert!(out.contains("V=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01"));
}

#[test]
fn example3_rng_timers_keys() {
    let out = run_text(
        "c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n",
    )
    .unwrap();
    let want = format!(
        "{}PC=021e I=0000 SP=0 DT=07 ST=00\nV=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n",
        blank_rows(32)
    );
    assert_eq!(out, want);
}

#[test]
fn zero_cycles_runs_nothing() {
    let m = run("6001", 0, "");
    assert_eq!(m.pc, 0x200);
    assert_eq!(m.v[0], 0);
}

#[test]
fn vf_flag_wins_when_x_is_f() {
    // VF = 0xFF; VF += VF -> carry sets VF = 1.
    let m = run("6fff8ff4", 2, "");
    assert_eq!(m.v[0xF], 1);
    // VF = 3; 8FF6 -> VF = 3 >> 1 = 1, flag = 1.
    let m = run("6f028ff6", 2, "");
    assert_eq!(m.v[0xF], 0);
}

#[test]
fn subtraction_flags() {
    // V0=5, V1=3: 8015 -> V0=2, VF=1; 8017 -> V0 = 3-2 = 1, VF=1.
    let m = run("600561038015", 3, "");
    assert_eq!((m.v[0], m.v[0xF]), (2, 1));
    let m = run("600361058015", 3, "");
    assert_eq!((m.v[0], m.v[0xF]), (254, 0));
}

#[test]
fn call_and_return() {
    // 0x200: call 0x206; 0x202: jump self; 0x206: ret
    let m = run("22061202000000ee", 2, "");
    assert_eq!(m.sp, 0);
    assert_eq!(m.pc, 0x202);
    let m = run("22061202000000ee", 1, "");
    assert_eq!(m.sp, 1);
    assert_eq!(m.pc, 0x206);
}

#[test]
fn bcd_and_register_transfer() {
    // V0=234; I=0x300; BCD; then F265 loads V0..V2 back from memory.
    let m = run("60eaa300f033f265", 4, "");
    assert_eq!(&m.mem[0x300..0x303], &[2, 3, 4]);
    let m = run("60eaa300f033f265", 5, "");
    assert_eq!(&m.v[..3], &[2, 3, 4]);
}

#[test]
fn fetch_wraps_at_end_of_memory() {
    // Jump to 0xFFF: low byte of the opcode comes from address 0.
    let m = run("1fff", 2, "");
    assert_eq!(m.pc, 0x001);
}

#[test]
fn key_schedule_skip_on_down() {
    // V0=5; EX9E skips next when key 5 down; then V1=1 (skipped) / V2=1.
    let m = run("6005e09e61016201", 4, "1:0020");
    assert_eq!(m.v[1], 0);
    assert_eq!(m.v[2], 1);
}

#[test]
fn event_at_n_has_no_effect() {
    let m = run("f00a", 3, "3:0001");
    assert_eq!(m.pc, 0x200);
    assert_eq!(m.v[0], 0);
}

#[test]
fn schedule_default_is_all_up() {
    let mut m = Machine::new(&[0xF0, 0x0A]).unwrap();
    m.run(4, &KeySchedule::default());
    assert_eq!(m.pc, 0x200);
}

#[test]
fn rom_size_limits() {
    assert!(Machine::new(&[0; 3584]).is_ok());
    assert!(Machine::new(&[0; 3585]).is_err());
    assert!(Machine::new(&[]).is_err());
}

#[test]
fn self_modifying_code() {
    // V0=0x62, V1=0x2a, I=0x208, store V0..V1 over the instruction at 0x208,
    // which then executes as `622a` (V2 = 0x2a).
    let m = run("6062612aa208f1550000", 5, "");
    assert_eq!(m.v[2], 0x2a);
}
