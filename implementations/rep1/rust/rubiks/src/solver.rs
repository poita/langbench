//! The four-phase solver.

use crate::coord::CornerGroup;
use crate::cubie::{CubeError, CubieCube};
use crate::moves::{Face, Move};
use crate::phase::{Phase, Phase1, Phase2, Phase3, Phase4};
use std::fmt;

/// Upper bound on solution length: 7 + 10 + 13 + 15 moves.
pub const MAX_SOLUTION_LEN: usize = 45;

/// Why a cube could not be solved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SolveError {
    /// The cube state is not a valid, solvable cube.
    InvalidCube(CubeError),
    /// An internal inconsistency: a phase could not make progress.
    Internal,
}

impl fmt::Display for SolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SolveError::InvalidCube(e) => write!(f, "invalid cube: {e}"),
            SolveError::Internal => f.write_str("internal solver error"),
        }
    }
}

impl std::error::Error for SolveError {}

impl From<CubeError> for SolveError {
    fn from(e: CubeError) -> Self {
        SolveError::InvalidCube(e)
    }
}

/// A Thistlethwaite solver holding the four distance tables.
///
/// Building a `Solver` fills the tables (a fraction of a second); it can then
/// solve any number of cubes, from any thread, by table-driven descent only.
pub struct Solver {
    phases: [Box<dyn Phase>; 4],
}

impl Solver {
    /// Builds all distance tables.
    pub fn new() -> Solver {
        let corners = CornerGroup::new(&half_turn_corner_perms());
        // The phases are independent; build them in parallel.
        let (p1, p2, p3, p4) = std::thread::scope(|s| {
            let h1 = s.spawn(Phase1::new);
            let h2 = s.spawn(Phase2::new);
            let c3 = corners.clone();
            let h3 = s.spawn(move || Phase3::new(c3));
            let h4 = s.spawn(|| Phase4::new(corners));
            (h1.join().unwrap(), h2.join().unwrap(), h3.join().unwrap(), h4.join().unwrap())
        });
        Solver { phases: [Box::new(p1), Box::new(p2), Box::new(p3), Box::new(p4)] }
    }

    /// The four phases, in order.
    pub fn phases(&self) -> &[Box<dyn Phase>; 4] {
        &self.phases
    }

    /// Solves `cube`, returning moves that bring it to the solved state
    /// (at most [`MAX_SOLUTION_LEN`] of them).
    pub fn solve(&self, cube: &CubieCube) -> Result<Vec<Move>, SolveError> {
        cube.verify()?;
        let mut cube = *cube;
        let mut solution = Vec::with_capacity(MAX_SOLUTION_LEN);
        for phase in &self.phases {
            let path = phase.solve(&cube).ok_or(SolveError::Internal)?;
            cube = cube.apply_all(&path);
            solution.extend(path);
        }
        if cube.is_solved() {
            Ok(merge_turns(&solution))
        } else {
            Err(SolveError::Internal)
        }
    }
}

impl Default for Solver {
    fn default() -> Self {
        Solver::new()
    }
}

/// Corner permutations of the six half turns.
fn half_turn_corner_perms() -> Vec<[u8; 8]> {
    Face::ALL.iter().map(|&f| CubieCube::from_move(Move::new(f, 2)).cp).collect()
}

/// Merges consecutive turns of the same face (`R R2` becomes `R'`, `U U'`
/// disappears), which can happen at phase boundaries. Never lengthens.
fn merge_turns(moves: &[Move]) -> Vec<Move> {
    let mut out: Vec<Move> = Vec::with_capacity(moves.len());
    for &m in moves {
        match out.last() {
            Some(&last) if last.face() == m.face() => {
                out.pop();
                let q = (last.quarter_turns() + m.quarter_turns()) % 4;
                if q != 0 {
                    out.push(Move::new(m.face(), q));
                }
            }
            _ => out.push(m),
        }
    }
    out
}
