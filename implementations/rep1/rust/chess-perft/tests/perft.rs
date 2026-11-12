//! Perft reference values for well-known positions.

use chess_perft::{Position, divide, perft};

const START: &str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
const KIWIPETE: &str = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
const POS3: &str = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
const POS4: &str = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1";
const POS5: &str = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8";
const POS6: &str = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10";

fn check(fen: &str, expected: &[u64]) {
    let pos = Position::from_fen(fen).unwrap();
    for (i, &n) in expected.iter().enumerate() {
        let depth = i as u32 + 1;
        assert_eq!(perft(&pos, depth), n, "{fen} depth {depth}");
    }
}

#[test]
fn start_position() {
    check(START, &[20, 400, 8902, 197_281]);
}

#[test]
fn kiwipete() {
    check(KIWIPETE, &[48, 2039, 97_862]);
}

#[test]
fn position_3() {
    check(POS3, &[14, 191, 2812, 43_238]);
}

#[test]
fn position_4() {
    check(POS4, &[6, 264, 9467]);
}

#[test]
fn position_4_mirrored() {
    check("r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1", &[6, 264, 9467]);
}

#[test]
fn position_5() {
    check(POS5, &[44, 1486, 62_379]);
}

#[test]
fn position_6() {
    check(POS6, &[46, 2079, 89_890]);
}

#[test]
fn depth_zero_is_one() {
    for fen in [START, "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"] {
        assert_eq!(perft(&Position::from_fen(fen).unwrap(), 0), 1);
    }
}

#[test]
fn stalemate_and_mate_have_no_nodes() {
    let stalemate = Position::from_fen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").unwrap();
    let mate = Position::from_fen("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1").unwrap();
    for pos in [stalemate, mate] {
        assert_eq!(pos.legal_moves().len(), 0);
        assert_eq!(perft(&pos, 1), 0);
        assert_eq!(perft(&pos, 3), 0);
        assert!(divide(&pos, 2).is_empty());
    }
}

#[test]
fn divide_sums_to_perft() {
    let pos = Position::from_fen(KIWIPETE).unwrap();
    let rows = divide(&pos, 3);
    assert_eq!(rows.len(), 48);
    assert_eq!(rows.iter().map(|r| r.1).sum::<u64>(), perft(&pos, 3));
}

#[test]
fn count_matches_generated_list() {
    for fen in [START, KIWIPETE, POS3, POS4, POS5, POS6] {
        let pos = Position::from_fen(fen).unwrap();
        assert_eq!(pos.count_legal_moves(), pos.legal_moves().len() as u64, "{fen}");
    }
}

/// Deeper runs; slow in debug builds, so run with `cargo test --release -- --ignored`.
#[test]
#[ignore]
fn deep_reference_values() {
    check(START, &[20, 400, 8902, 197_281, 4_865_609]);
    check(KIWIPETE, &[48, 2039, 97_862, 4_085_603]);
    check(POS3, &[14, 191, 2812, 43_238, 674_624]);
    check(POS4, &[6, 264, 9467, 422_333]);
    check(POS5, &[44, 1486, 62_379, 2_103_487]);
    check(POS6, &[46, 2079, 89_890, 3_894_594]);
}
