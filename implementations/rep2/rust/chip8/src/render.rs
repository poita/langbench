//! Formatting of a machine's final state as text.

use crate::display::{Display, HEIGHT};
use crate::machine::Machine;
use std::fmt::Write;

/// Renders the display as 32 lines of 64 characters (`#` lit, `.` unlit),
/// each terminated by `\n`.
pub fn render_display(display: &Display) -> String {
    let mut out = String::with_capacity(HEIGHT * 65);
    for y in 0..HEIGHT {
        out.extend(display.row(y).iter().map(|&p| if p { '#' } else { '.' }));
        out.push('\n');
    }
    out
}

/// Renders the CPU state line (`PC=… I=… SP=… DT=… ST=…`) followed by the
/// register line (`V=…`), each terminated by `\n`.
pub fn render_state(machine: &Machine) -> String {
    let mut out = String::new();
    let _ = writeln!(
        out,
        "PC={:04x} I={:04x} SP={} DT={:02x} ST={:02x}",
        machine.pc(),
        machine.index(),
        machine.sp(),
        machine.delay_timer(),
        machine.sound_timer()
    );
    out.push_str("V=");
    for (k, v) in machine.registers().iter().enumerate() {
        if k > 0 {
            out.push(' ');
        }
        let _ = write!(out, "{v:02x}");
    }
    out.push('\n');
    out
}

/// Renders the complete 34-line output: display, then state and registers.
pub fn render(machine: &Machine) -> String {
    let mut out = render_display(machine.display());
    out.push_str(&render_state(machine));
    out
}
