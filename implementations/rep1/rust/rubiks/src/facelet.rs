//! The 54-sticker model of the cube, exactly as laid out in the specification.
//!
//! Facelet `n` (1-9) of face `X` has index `X.index() * 9 + n - 1`, with the
//! faces ordered `U R F D L B`. A [`FaceletCube`] stores, for every facelet,
//! the face whose centre colour the sticker there has.

use crate::cubie::{CubeError, CubieCube};
use crate::moves::{Face, Move};
use std::fmt;
use std::str::FromStr;
use std::sync::OnceLock;

/// Corner cubie facelet triples; the first facelet is the U/D one and the
/// triple runs clockwise around the corner.
const CORNERS: [&str; 8] = [
    "U9 R1 F3", "U7 F1 L3", "U1 L1 B3", "U3 B1 R3", "D3 F9 R7", "D1 L9 F7", "D7 B9 L7",
    "D9 R9 B7",
];

/// Edge cubie facelet pairs; the first facelet is the U/D one (or F/B for the
/// middle-layer edges).
const EDGES: [&str; 12] = [
    "U6 R2", "U8 F2", "U4 L2", "U2 B2", "D6 R8", "D2 F8", "D4 L8", "D8 B8", "F6 R4", "F4 L6",
    "B6 L4", "B4 R6",
];

/// Clockwise quarter turn of each face as facelet 4-cycles `(a b c d)`: the
/// sticker at `a` moves to `b`, and so on.
const CYCLES: [&str; 6] = [
    "(U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)",
    "(R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)",
    "(F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)",
    "(D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)",
    "(L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)",
    "(B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)",
];

/// Index of a facelet name such as `"U9"`.
fn facelet_index(name: &str) -> usize {
    let mut chars = name.chars();
    let face = Face::from_char(chars.next().expect("empty facelet name")).expect("bad face");
    let n = chars.next().and_then(|c| c.to_digit(10)).expect("bad facelet number") as usize;
    face.index() * 9 + n - 1
}

pub(crate) struct Layout {
    pub corners: [[usize; 3]; 8],
    pub edges: [[usize; 2]; 12],
    /// `src[move][i]`: after the move, facelet `i` shows what was at `src[move][i]`.
    pub src: [[u8; 54]; 18],
}

pub(crate) fn layout() -> &'static Layout {
    static LAYOUT: OnceLock<Layout> = OnceLock::new();
    LAYOUT.get_or_init(|| {
        let mut corners = [[0; 3]; 8];
        for (c, text) in corners.iter_mut().zip(CORNERS) {
            for (slot, name) in c.iter_mut().zip(text.split(' ')) {
                *slot = facelet_index(name);
            }
        }
        let mut edges = [[0; 2]; 12];
        for (e, text) in edges.iter_mut().zip(EDGES) {
            for (slot, name) in e.iter_mut().zip(text.split(' ')) {
                *slot = facelet_index(name);
            }
        }
        let mut src = [[0u8; 54]; 18];
        for (face, text) in CYCLES.iter().enumerate() {
            let mut one: [u8; 54] = std::array::from_fn(|i| i as u8);
            for cycle in text.split(')').filter(|c| !c.is_empty()) {
                let idx: Vec<usize> =
                    cycle.trim_start_matches('(').split(' ').map(facelet_index).collect();
                for k in 0..idx.len() {
                    one[idx[(k + 1) % idx.len()]] = idx[k] as u8;
                }
            }
            let two: [u8; 54] = std::array::from_fn(|i| one[one[i] as usize]);
            let three: [u8; 54] = std::array::from_fn(|i| one[two[i] as usize]);
            src[face * 3] = one;
            src[face * 3 + 1] = two;
            src[face * 3 + 2] = three;
        }
        Layout { corners, edges, src }
    })
}

/// A cube described sticker by sticker.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct FaceletCube {
    colors: [Face; 54],
}

impl FaceletCube {
    /// The solved cube.
    pub fn solved() -> FaceletCube {
        FaceletCube { colors: std::array::from_fn(|i| Face::from_index(i / 9)) }
    }

    /// The colour (face of origin) of facelet `i` (`0..54`).
    pub fn color(&self, i: usize) -> Face {
        self.colors[i]
    }

    /// Applies one move.
    pub fn apply(&self, m: Move) -> FaceletCube {
        let src = &layout().src[m.index()];
        FaceletCube { colors: std::array::from_fn(|i| self.colors[src[i] as usize]) }
    }

    /// Applies a sequence of moves left to right.
    pub fn apply_all(&self, moves: &[Move]) -> FaceletCube {
        moves.iter().fold(*self, |c, &m| c.apply(m))
    }

    /// Whether every face shows a single colour.
    pub fn is_solved(&self) -> bool {
        *self == FaceletCube::solved()
    }

    /// Converts to the cubie model, checking that the stickers form real
    /// cubies and that the cube is solvable.
    pub fn to_cubie(&self) -> Result<CubieCube, CubeError> {
        let lay = layout();
        let mut cube = CubieCube::SOLVED;
        let mut seen_c = [false; 8];
        for (pos, tri) in lay.corners.iter().enumerate() {
            let cols = tri.map(|f| self.colors[f]);
            let k = cols
                .iter()
                .position(|&c| c == Face::U || c == Face::D)
                .ok_or(CubeError::BadFacelets)?;
            let rot = [cols[k], cols[(k + 1) % 3], cols[(k + 2) % 3]];
            let j = (0..8)
                .find(|&j| lay.corners[j].map(|f| Face::from_index(f / 9)) == rot)
                .ok_or(CubeError::BadFacelets)?;
            if std::mem::replace(&mut seen_c[j], true) {
                return Err(CubeError::BadFacelets);
            }
            cube.cp[pos] = j as u8;
            cube.co[pos] = k as u8;
        }
        let mut seen_e = [false; 12];
        for (pos, pair) in lay.edges.iter().enumerate() {
            let cols = pair.map(|f| self.colors[f]);
            let found = (0..12).find_map(|j| {
                let home = lay.edges[j].map(|f| Face::from_index(f / 9));
                if home == cols {
                    Some((j, 0))
                } else if home == [cols[1], cols[0]] {
                    Some((j, 1))
                } else {
                    None
                }
            });
            let (j, o) = found.ok_or(CubeError::BadFacelets)?;
            if std::mem::replace(&mut seen_e[j], true) {
                return Err(CubeError::BadFacelets);
            }
            cube.ep[pos] = j as u8;
            cube.eo[pos] = o;
        }
        cube.verify()?;
        Ok(cube)
    }

    /// Builds the facelet model of a cubie cube.
    pub fn from_cubie(cube: &CubieCube) -> FaceletCube {
        let lay = layout();
        let mut colors = FaceletCube::solved().colors;
        for pos in 0..8 {
            let j = cube.cp[pos] as usize;
            let o = cube.co[pos] as usize;
            for k in 0..3 {
                colors[lay.corners[pos][k]] = Face::from_index(lay.corners[j][(k + 3 - o) % 3] / 9);
            }
        }
        for pos in 0..12 {
            let j = cube.ep[pos] as usize;
            let o = cube.eo[pos] as usize;
            for k in 0..2 {
                colors[lay.edges[pos][k]] = Face::from_index(lay.edges[j][k ^ o] / 9);
            }
        }
        FaceletCube { colors }
    }
}

impl fmt::Display for FaceletCube {
    /// 54 characters: the nine facelets of `U`, `R`, `F`, `D`, `L`, `B` in turn.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for c in self.colors {
            write!(f, "{c}")?;
        }
        Ok(())
    }
}

impl FromStr for FaceletCube {
    type Err = CubeError;
    /// Parses the format produced by [`fmt::Display`]. This only checks the
    /// characters; use [`FaceletCube::to_cubie`] to validate the cube.
    fn from_str(s: &str) -> Result<FaceletCube, CubeError> {
        let chars: Vec<char> = s.chars().collect();
        if chars.len() != 54 {
            return Err(CubeError::BadFacelets);
        }
        let mut colors = [Face::U; 54];
        for (slot, c) in colors.iter_mut().zip(chars) {
            *slot = Face::from_char(c).ok_or(CubeError::BadFacelets)?;
        }
        Ok(FaceletCube { colors })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solved_string() {
        let s = FaceletCube::solved().to_string();
        assert_eq!(s, "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB");
        assert_eq!(s.parse::<FaceletCube>().unwrap(), FaceletCube::solved());
    }

    #[test]
    fn u_move_matches_spec_example() {
        let c = FaceletCube::solved().apply("U".parse().unwrap());
        let s = c.to_string();
        // F1 F2 F3 show R, L1-3 show F, B1-3 show L, R1-3 show B.
        assert_eq!(&s[18..21], "RRR");
        assert_eq!(&s[36..39], "FFF");
        assert_eq!(&s[45..48], "LLL");
        assert_eq!(&s[9..12], "BBB");
    }
}
