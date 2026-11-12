//! # rubiks
//!
//! A Rubik's cube solver built on Thistlethwaite's four-phase algorithm.
//!
//! The cube is modelled at three levels, each in its own module:
//!
//! * [`moves`] – the 18 face turns ([`Move`]) and parsing/printing of move
//!   sequences such as `"R U R' U'"`.
//! * [`facelet`] – the 54-sticker model defined by the specification's net
//!   ([`FaceletCube`]); it is the ground truth for what each move does.
//! * [`cubie`] – the compact cubie model ([`CubieCube`]: permutation and
//!   orientation of 8 corners and 12 edges), used for fast move application.
//!
//! The solver proper lives in [`phase`] (the four subgroup-descent phases,
//! each with a coordinate, move tables and an exact distance table) and
//! [`solver`] (the [`Solver`] façade chaining them). [`perm`] and [`coord`]
//! hold the combinatorial helpers behind the coordinates.
//!
//! ## Example
//!
//! ```
//! use rubiks::{parse_moves, format_moves, CubieCube, Solver};
//!
//! let scramble = parse_moves("R U2 F' D L2 B").unwrap();
//! let cube = CubieCube::SOLVED.apply_all(&scramble);
//!
//! let solver = Solver::new(); // builds the distance tables once
//! let solution = solver.solve(&cube).unwrap();
//! assert!(solution.len() <= 45);
//! assert!(cube.apply_all(&solution).is_solved());
//! println!("{}", format_moves(&solution));
//! ```

pub mod coord;
pub mod cubie;
pub mod facelet;
pub mod moves;
pub mod perm;
pub mod phase;
pub mod solver;

pub use cubie::{CubeError, CubieCube};
pub use facelet::FaceletCube;
pub use moves::{format_moves, parse_moves, Face, Move, ParseMoveError};
pub use solver::{SolveError, Solver};
