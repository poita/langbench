//! The four phases of Thistlethwaite's algorithm.
//!
//! Each phase works in the subgroup chain
//! `G0 = <all> ⊃ G1 = <U D L R F2 B2> ⊃ G2 = <U D L2 R2 F2 B2> ⊃ G3 = <half turns> ⊃ {1}`
//! and moves a cube from `G(i-1)` into `G(i)` using the moves of `G(i-1)`.
//! A phase is described by a [coordinate](crate::coord) identifying the
//! coset of `G(i)` the cube is in, a transition table per allowed move, and
//! an exact distance table (breadth-first search from the goal over the
//! coordinate graph). Solving a phase is then a greedy descent of the
//! distance table.

use crate::coord::{self, CornerGroup};
use crate::cubie::CubieCube;
use crate::moves::{Face, Move};
use crate::perm::{self, Subsets};

/// Distance value marking coordinates not reachable from the goal.
pub const UNREACHED: u8 = u8::MAX;

/// One phase of the solver.
pub trait Phase: Send + Sync {
    /// The moves this phase may use; `step` columns follow this order.
    fn moves(&self) -> &[Move];
    /// The phase coordinate of `cube`, or `None` if the cube is not in the
    /// subgroup the phase starts from (or is otherwise invalid).
    fn coord(&self, cube: &CubieCube) -> Option<usize>;
    /// The coordinate after applying `moves()[slot]` to a cube with coordinate `c`.
    fn step(&self, c: usize, slot: usize) -> usize;
    /// Exact number of phase moves needed from each coordinate to the goal.
    fn dist(&self) -> &[u8];

    /// The optimal move sequence taking `cube` to the goal of this phase, or
    /// `None` if the cube is not in this phase's starting group.
    fn solve(&self, cube: &CubieCube) -> Option<Vec<Move>> {
        let mut c = self.coord(cube)?;
        let dist = self.dist();
        let mut d = dist[c];
        if d == UNREACHED {
            return None;
        }
        let moves = self.moves();
        let mut out = Vec::with_capacity(d as usize);
        while d > 0 {
            let (slot, next) = (0..moves.len())
                .map(|s| (s, self.step(c, s)))
                .find(|&(_, n)| dist[n] == d - 1)?;
            out.push(moves[slot]);
            c = next;
            d -= 1;
        }
        Some(out)
    }
}

/// Breadth-first search over `size` coordinates from `goal`. The move set
/// must be closed under inversion so that distances to and from the goal agree.
fn bfs(size: usize, goal: usize, n_moves: usize, step: impl Fn(usize, usize) -> usize) -> Vec<u8> {
    let mut dist = vec![UNREACHED; size];
    let mut queue = Vec::with_capacity(size);
    dist[goal] = 0;
    queue.push(goal as u32);
    let mut head = 0;
    while head < queue.len() {
        let c = queue[head] as usize;
        head += 1;
        for s in 0..n_moves {
            let n = step(c, s);
            if dist[n] == UNREACHED {
                dist[n] = dist[c] + 1;
                queue.push(n as u32);
            }
        }
    }
    dist
}

fn is_half_or_face(m: Move, quarter_faces: &[Face]) -> bool {
    m.is_half_turn() || quarter_faces.contains(&m.face())
}

/// Phase 1 moves: all eighteen.
pub fn phase1_moves() -> Vec<Move> {
    Move::ALL.to_vec()
}

/// Phase 2 moves: everything except quarter turns of `F` and `B`.
pub fn phase2_moves() -> Vec<Move> {
    Move::ALL
        .into_iter()
        .filter(|&m| is_half_or_face(m, &[Face::U, Face::D, Face::L, Face::R]))
        .collect()
}

/// Phase 3 moves: turns of `U` and `D`, half turns of `L R F B`.
pub fn phase3_moves() -> Vec<Move> {
    Move::ALL.into_iter().filter(|&m| is_half_or_face(m, &[Face::U, Face::D])).collect()
}

/// Phase 4 moves: the six half turns.
pub fn phase4_moves() -> Vec<Move> {
    Move::ALL.into_iter().filter(|m| m.is_half_turn()).collect()
}

// ---------------------------------------------------------------- phase 1

/// Phase 1: orient all edges (`G0 -> G1`).
pub struct Phase1 {
    moves: Vec<Move>,
    table: Vec<u16>,
    dist: Vec<u8>,
}

impl Phase1 {
    pub fn new() -> Phase1 {
        let moves = phase1_moves();
        let n = moves.len();
        let mut table = vec![0u16; coord::N_EO * n];
        for c in 0..coord::N_EO {
            let eo = coord::eo_decode(c);
            for (s, &m) in moves.iter().enumerate() {
                let mc = CubieCube::from_move(m);
                let mut next = [0u8; 12];
                for i in 0..12 {
                    next[i] = eo[mc.ep[i] as usize] ^ mc.eo[i];
                }
                table[c * n + s] = coord::eo_coord(&next) as u16;
            }
        }
        let dist = bfs(coord::N_EO, 0, n, |c, s| table[c * n + s] as usize);
        Phase1 { moves, table, dist }
    }
}

impl Default for Phase1 {
    fn default() -> Self {
        Self::new()
    }
}

impl Phase for Phase1 {
    fn moves(&self) -> &[Move] {
        &self.moves
    }
    fn coord(&self, cube: &CubieCube) -> Option<usize> {
        Some(coord::eo_coord(&cube.eo))
    }
    fn step(&self, c: usize, slot: usize) -> usize {
        self.table[c * self.moves.len() + slot] as usize
    }
    fn dist(&self) -> &[u8] {
        &self.dist
    }
}

// ---------------------------------------------------------------- phase 2

/// Phase 2: orient the corners and put the E-slice edges in the E slice
/// (`G1 -> G2`).
pub struct Phase2 {
    moves: Vec<Move>,
    subsets: Subsets,
    co_table: Vec<u16>,
    es_table: Vec<u16>,
    dist: Vec<u8>,
}

impl Phase2 {
    pub fn new() -> Phase2 {
        let moves = phase2_moves();
        let n = moves.len();
        let subsets = Subsets::new(12, 4);
        let mut co_table = vec![0u16; coord::N_CO * n];
        for c in 0..coord::N_CO {
            let co = coord::co_decode(c);
            for (s, &m) in moves.iter().enumerate() {
                let mc = CubieCube::from_move(m);
                let mut next = [0u8; 8];
                for i in 0..8 {
                    next[i] = (co[mc.cp[i] as usize] + mc.co[i]) % 3;
                }
                co_table[c * n + s] = coord::co_coord(&next) as u16;
            }
        }
        let mut es_table = vec![0u16; coord::N_ESLICE * n];
        for c in 0..coord::N_ESLICE {
            let mask = subsets.mask(c);
            for (s, &m) in moves.iter().enumerate() {
                let mc = CubieCube::from_move(m);
                let next = (0..12)
                    .filter(|&i| mask >> mc.ep[i] & 1 == 1)
                    .fold(0u32, |acc, i| acc | 1 << i);
                es_table[c * n + s] = subsets.rank(next) as u16;
            }
        }
        let goal_mask = 0b1111_0000_0000;
        let goal = subsets.rank(goal_mask); // co = 0
        let size = coord::N_CO * coord::N_ESLICE;
        let dist = bfs(size, goal, n, |c, s| {
            let (co, es) = (c / coord::N_ESLICE, c % coord::N_ESLICE);
            co_table[co * n + s] as usize * coord::N_ESLICE + es_table[es * n + s] as usize
        });
        Phase2 { moves, subsets, co_table, es_table, dist }
    }
}

impl Default for Phase2 {
    fn default() -> Self {
        Self::new()
    }
}

impl Phase for Phase2 {
    fn moves(&self) -> &[Move] {
        &self.moves
    }
    fn coord(&self, cube: &CubieCube) -> Option<usize> {
        if cube.eo.iter().any(|&o| o != 0) {
            return None;
        }
        let es = self.subsets.rank(coord::eslice_mask(&cube.ep));
        Some(coord::co_coord(&cube.co) * coord::N_ESLICE + es)
    }
    fn step(&self, c: usize, slot: usize) -> usize {
        let n = self.moves.len();
        let (co, es) = (c / coord::N_ESLICE, c % coord::N_ESLICE);
        self.co_table[co * n + slot] as usize * coord::N_ESLICE
            + self.es_table[es * n + slot] as usize
    }
    fn dist(&self) -> &[u8] {
        &self.dist
    }
}

// ---------------------------------------------------------------- phase 3

/// Phase 3: bring the corners into the half-turn group's orbit and the
/// M-slice edges into the M slice (`G2 -> G3`).
pub struct Phase3 {
    moves: Vec<Move>,
    corners: CornerGroup,
    subsets: Subsets,
    cc_table: Vec<u16>,
    m_table: Vec<u16>,
    dist: Vec<u8>,
}

impl Phase3 {
    pub fn new(corners: CornerGroup) -> Phase3 {
        let moves = phase3_moves();
        let n = moves.len();
        let subsets = Subsets::new(8, 4);
        let mut cc_table = vec![0u16; coord::N_CORNER_CLASS * n];
        for c in 0..coord::N_CORNER_CLASS {
            let p = perm::unrank(8, corners.class_rep[c] as usize);
            for (s, &m) in moves.iter().enumerate() {
                let mc = CubieCube::from_move(m);
                let q: [u8; 8] = std::array::from_fn(|i| p[mc.cp[i] as usize]);
                cc_table[c * n + s] = corners.class_of[perm::rank(&q)];
            }
        }
        let mut m_table = vec![0u16; coord::N_MSLICE * n];
        for c in 0..coord::N_MSLICE {
            let mask = subsets.mask(c);
            for (s, &m) in moves.iter().enumerate() {
                let mc = CubieCube::from_move(m);
                let mut next = 0u32;
                for i in 0..8 {
                    let src = mc.ep[i] as usize;
                    assert!(src < 8, "phase 3 moves keep the E-slice edges in place");
                    next |= (mask >> src & 1) << i;
                }
                m_table[c * n + s] = subsets.rank(next) as u16;
            }
        }
        let goal_class = corners.class(&[0, 1, 2, 3, 4, 5, 6, 7]);
        let goal = goal_class * coord::N_MSLICE + subsets.rank(0b1010_1010);
        let size = coord::N_CORNER_CLASS * coord::N_MSLICE;
        let dist = bfs(size, goal, n, |c, s| {
            let (cc, m) = (c / coord::N_MSLICE, c % coord::N_MSLICE);
            cc_table[cc * n + s] as usize * coord::N_MSLICE + m_table[m * n + s] as usize
        });
        Phase3 { moves, corners, subsets, cc_table, m_table, dist }
    }
}

impl Phase for Phase3 {
    fn moves(&self) -> &[Move] {
        &self.moves
    }
    fn coord(&self, cube: &CubieCube) -> Option<usize> {
        if cube.eo.iter().any(|&o| o != 0)
            || cube.co.iter().any(|&o| o != 0)
            || coord::eslice_mask(&cube.ep) != 0b1111_0000_0000
        {
            return None;
        }
        let m = self.subsets.rank(coord::mslice_mask(&cube.ep));
        Some(self.corners.class(&cube.cp) * coord::N_MSLICE + m)
    }
    fn step(&self, c: usize, slot: usize) -> usize {
        let n = self.moves.len();
        let (cc, m) = (c / coord::N_MSLICE, c % coord::N_MSLICE);
        self.cc_table[cc * n + slot] as usize * coord::N_MSLICE + self.m_table[m * n + slot] as usize
    }
    fn dist(&self) -> &[u8] {
        &self.dist
    }
}

// ---------------------------------------------------------------- phase 4

/// Phase 4: solve the cube using only half turns (`G3 -> {1}`).
pub struct Phase4 {
    moves: Vec<Move>,
    corners: CornerGroup,
    corner_table: Vec<u8>,
    /// Indexed `[slice][perm * moves + slot]`.
    slice_table: [Vec<u8>; 3],
    dist: Vec<u8>,
}

impl Phase4 {
    pub fn new(corners: CornerGroup) -> Phase4 {
        let moves = phase4_moves();
        let n = moves.len();
        let h = coord::N_HALF_TURN_CORNERS;
        let mut corner_table = vec![0u8; h * n];
        for (i, p) in corners.elements.iter().enumerate() {
            for (s, &m) in moves.iter().enumerate() {
                let mc = CubieCube::from_move(m);
                let q: [u8; 8] = std::array::from_fn(|k| p[mc.cp[k] as usize]);
                corner_table[i * n + s] =
                    corners.element(&q).expect("half turns stay in the half-turn group") as u8;
            }
        }
        let slice_table: [Vec<u8>; 3] = std::array::from_fn(|slice| {
            let cubies = &coord::SLICE_EDGES[slice];
            let mut t = vec![0u8; coord::N_SLICE_PERM * n];
            for r in 0..coord::N_SLICE_PERM {
                let q = perm::unrank(4, r);
                for (s, &m) in moves.iter().enumerate() {
                    let mc = CubieCube::from_move(m);
                    let next: Vec<u8> = cubies
                        .iter()
                        .map(|&pos| {
                            let src = mc.ep[pos as usize];
                            let ls = cubies
                                .iter()
                                .position(|&c| c == src)
                                .expect("half turns keep edges within their slice");
                            q[ls]
                        })
                        .collect();
                    t[r * n + s] = perm::rank(&next) as u8;
                }
            }
            t
        });
        let size = h * coord::N_SLICE_PERM.pow(3);
        let sp = coord::N_SLICE_PERM;
        let goal = 0;
        let dist = bfs(size, goal, n, |c, s| {
            let ps = c % sp;
            let pm = c / sp % sp;
            let pe = c / (sp * sp) % sp;
            let ci = c / (sp * sp * sp);
            let ci = corner_table[ci * n + s] as usize;
            let pe = slice_table[0][pe * n + s] as usize;
            let pm = slice_table[1][pm * n + s] as usize;
            let ps = slice_table[2][ps * n + s] as usize;
            ((ci * sp + pe) * sp + pm) * sp + ps
        });
        Phase4 { moves, corners, corner_table, slice_table, dist }
    }
}

impl Phase for Phase4 {
    fn moves(&self) -> &[Move] {
        &self.moves
    }
    fn coord(&self, cube: &CubieCube) -> Option<usize> {
        if cube.eo.iter().any(|&o| o != 0) || cube.co.iter().any(|&o| o != 0) {
            return None;
        }
        let ci = self.corners.element(&cube.cp)?;
        let pe = coord::slice_perm_coord(&cube.ep, 0)?;
        let pm = coord::slice_perm_coord(&cube.ep, 1)?;
        let ps = coord::slice_perm_coord(&cube.ep, 2)?;
        let sp = coord::N_SLICE_PERM;
        Some(((ci * sp + pe) * sp + pm) * sp + ps)
    }
    fn step(&self, c: usize, slot: usize) -> usize {
        let n = self.moves.len();
        let sp = coord::N_SLICE_PERM;
        let ps = c % sp;
        let pm = c / sp % sp;
        let pe = c / (sp * sp) % sp;
        let ci = c / (sp * sp * sp);
        let ci = self.corner_table[ci * n + slot] as usize;
        let pe = self.slice_table[0][pe * n + slot] as usize;
        let pm = self.slice_table[1][pm * n + slot] as usize;
        let ps = self.slice_table[2][ps * n + slot] as usize;
        ((ci * sp + pe) * sp + pm) * sp + ps
    }
    fn dist(&self) -> &[u8] {
        &self.dist
    }
}
