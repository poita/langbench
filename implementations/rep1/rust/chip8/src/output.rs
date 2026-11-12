//! Rendering of the final machine state.

use crate::machine::Machine;
use std::fmt;

/// Wrapper that formats a [`Machine`] as the 34-line report: 32 display
/// rows, the `PC=… I=… SP=… DT=… ST=…` line and the `V=…` line.
pub struct Report<'a>(pub &'a Machine);

impl fmt::Display for Report<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let m = self.0;
        write!(f, "{}", m.display)?;
        writeln!(
            f,
            "PC={:04x} I={:04x} SP={} DT={:02x} ST={:02x}",
            m.pc, m.i, m.sp, m.dt, m.st
        )?;
        write!(f, "V=")?;
        for (k, v) in m.v.iter().enumerate() {
            if k > 0 {
                write!(f, " ")?;
            }
            write!(f, "{v:02x}")?;
        }
        writeln!(f)
    }
}
