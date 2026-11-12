//! Checks of the cube model against the sanity properties in the spec.

use rubiks::{format_moves, parse_moves, CubieCube, FaceletCube, Move};

mod common;
use common::Rng;

fn order(seq: &str) -> usize {
    let moves = parse_moves(seq).unwrap();
    let mut c = CubieCube::SOLVED.apply_all(&moves);
    let mut n = 1;
    while !c.is_solved() {
        c = c.apply_all(&moves);
        n += 1;
    }
    n
}

#[test]
fn quarter_turns_have_order_four() {
    for face in ["U", "D", "L", "R", "F", "B"] {
        assert_eq!(order(face), 4);
        assert_eq!(order(&format!("{face}2")), 2);
    }
}

#[test]
fn known_orders() {
    assert_eq!(order("R U R' U'"), 6);
    assert_eq!(order("R U"), 105);
    assert_eq!(order("U D"), 4);
}

#[test]
fn prime_and_double_agree_with_repeats() {
    for m in Move::ALL {
        let base = Move::new(m.face(), 1);
        let rep = vec![base; m.quarter_turns() as usize];
        assert_eq!(CubieCube::SOLVED.apply(m), CubieCube::SOLVED.apply_all(&rep));
    }
}

#[test]
fn superflip() {
    let seq = parse_moves("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2").unwrap();
    let c = CubieCube::SOLVED.apply_all(&seq);
    assert_eq!(c.cp, CubieCube::SOLVED.cp);
    assert_eq!(c.co, [0; 8]);
    assert_eq!(c.ep, CubieCube::SOLVED.ep);
    assert_eq!(c.eo, [1; 12]);
}

#[test]
fn single_move_facelets_match_spec() {
    // R has the cycle (F3 U3 B7 D3): the sticker at D3 moves to F3, F3 to U3.
    let f = FaceletCube::solved().apply("R".parse().unwrap()).to_string();
    // Facelet strings are in U R F D L B order: F3 is index 18 + 2.
    assert_eq!(f.as_bytes()[20], b'D');
    assert_eq!(f.as_bytes()[2], b'F'); // U3
}

#[test]
fn cubie_and_facelet_models_agree_on_random_sequences() {
    let mut rng = Rng(0x1234_5678_9abc_def1);
    for _ in 0..200 {
        let seq = rng.moves(30);
        let cubie = CubieCube::SOLVED.apply_all(&seq);
        let facelet = FaceletCube::solved().apply_all(&seq);
        assert_eq!(cubie.to_facelets(), facelet, "{}", format_moves(&seq));
        assert_eq!(facelet.to_cubie().unwrap(), cubie);
        assert_eq!(cubie.verify(), Ok(()));
    }
}

#[test]
fn random_states_are_valid() {
    let mut rng = Rng(42);
    for _ in 0..50 {
        let c = rng.cube();
        assert_eq!(c.to_facelets().to_cubie().unwrap(), c);
    }
}
