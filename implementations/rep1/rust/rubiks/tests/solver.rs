//! End-to-end tests of the phases and the solver.

use rubiks::coord;
use rubiks::phase::{Phase, UNREACHED};
use rubiks::solver::MAX_SOLUTION_LEN;
use rubiks::{format_moves, parse_moves, CubieCube, SolveError};

mod common;
use common::{solver, Rng};

fn max_dist(p: &dyn Phase) -> u8 {
    p.dist().iter().copied().filter(|&d| d != UNREACHED).max().unwrap()
}

#[test]
fn table_sizes_and_depths() {
    let s = solver();
    let p = s.phases();
    assert_eq!(p[0].dist().len(), coord::N_EO);
    assert_eq!(p[1].dist().len(), 1_082_565);
    assert_eq!(p[2].dist().len(), 29_400);
    assert_eq!(p[3].dist().len(), 1_327_104);
    assert_eq!(max_dist(&*p[0]), 7);
    assert_eq!(max_dist(&*p[1]), 10);
    assert_eq!(max_dist(&*p[2]), 13);
    assert_eq!(max_dist(&*p[3]), 15);
}

#[test]
fn move_sets_have_expected_sizes() {
    let p = solver().phases();
    let sizes: Vec<usize> = p.iter().map(|ph| ph.moves().len()).collect();
    assert_eq!(sizes, [18, 14, 10, 6]);
}

#[test]
fn solves_trivial_cubes() {
    assert!(solver().solve(&CubieCube::SOLVED).unwrap().is_empty());
    let c = CubieCube::SOLVED.apply_all(&parse_moves("R").unwrap());
    let sol = solver().solve(&c).unwrap();
    assert!(c.apply_all(&sol).is_solved());
    assert!(sol.len() <= 4);
}

#[test]
fn solves_superflip_and_friends() {
    for scramble in [
        "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2",
        "U2 D2 R2 L2 F2 B2",
        "R2 L2 U2 D2 F2 B2",
        "F U' F2 D' B U R' F' L D' R' U' L U B' D2 R' F U2 D2",
    ] {
        let c = CubieCube::SOLVED.apply_all(&parse_moves(scramble).unwrap());
        let sol = solver().solve(&c).unwrap();
        assert!(sol.len() <= MAX_SOLUTION_LEN, "{scramble}: {}", format_moves(&sol));
        assert!(c.apply_all(&sol).is_solved(), "{scramble}");
    }
}

#[test]
fn solves_random_scrambles() {
    let mut rng = Rng(7);
    for n in [1, 2, 3, 5, 10, 20, 25, 50, 200] {
        for _ in 0..20 {
            let c = CubieCube::SOLVED.apply_all(&rng.moves(n));
            let sol = solver().solve(&c).unwrap();
            assert!(sol.len() <= MAX_SOLUTION_LEN);
            assert!(c.apply_all(&sol).is_solved());
        }
    }
}

#[test]
fn solves_uniformly_random_states() {
    let mut rng = Rng(0xdead_beef_cafe);
    for _ in 0..300 {
        let c = rng.cube();
        let sol = solver().solve(&c).unwrap();
        assert!(sol.len() <= MAX_SOLUTION_LEN, "{}", format_moves(&sol));
        assert!(c.apply_all(&sol).is_solved());
    }
}

#[test]
fn phase_goals_are_reached_in_order() {
    let mut rng = Rng(99);
    let mut c = rng.cube();
    let phases = solver().phases();
    for (i, ph) in phases.iter().enumerate() {
        let path = ph.solve(&c).unwrap();
        assert_eq!(path.len() as u8, ph.dist()[ph.coord(&c).unwrap()]);
        assert!(path.iter().all(|m| ph.moves().contains(m)), "phase {}", i + 1);
        c = c.apply_all(&path);
        if let Some(next) = phases.get(i + 1) {
            assert_ne!(next.dist()[next.coord(&c).unwrap()], UNREACHED);
        }
    }
    assert!(c.is_solved());
}

#[test]
fn rejects_unsolvable_cubes() {
    let mut c = CubieCube::SOLVED;
    c.co[0] = 1;
    assert!(matches!(solver().solve(&c), Err(SolveError::InvalidCube(_))));
}
