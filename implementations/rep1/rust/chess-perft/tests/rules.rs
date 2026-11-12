//! Targeted tests of individual chess rules via legal move lists.

use chess_perft::{Position, perft};

fn moves(fen: &str) -> Vec<String> {
    let mut v: Vec<String> =
        Position::from_fen(fen).unwrap().legal_moves().iter().map(|m| m.to_string()).collect();
    v.sort();
    v
}

fn has(fen: &str, mv: &str) -> bool {
    moves(fen).iter().any(|m| m == mv)
}

#[test]
fn en_passant_basic() {
    let fen = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1";
    assert!(has(fen, "e5d6"));
    assert!(has(fen, "e5e6"));
    // Same placement without an ep square: no capture.
    assert!(!has("4k3/8/8/3pP3/8/8/8/4K3 w - - 0 1", "e5d6"));
}

#[test]
fn en_passant_square_without_capturing_pawn_is_harmless() {
    assert_eq!(moves("4k3/8/8/8/3pP3/8/8/4K3 w - e3 0 1").len(), 6);
}

#[test]
fn en_passant_horizontal_pin() {
    // Removing both pawns would expose the white king to the rook on h5.
    let fen = "8/8/8/K2pP2r/8/8/8/4k3 w - d6 0 1";
    assert!(!has(fen, "e5d6"));
    assert!(has(fen, "e5e6"));
}

#[test]
fn en_passant_diagonal_pin() {
    // Pawn e5 is pinned by the bishop on h8 against the king on b2.
    let fen = "4k2b/8/8/3pP3/8/8/1K6/8 w - d6 0 1";
    assert!(!has(fen, "e5d6"));
}

#[test]
fn en_passant_captures_checking_pawn() {
    // Black pawn on d5 just advanced and gives check to the king on e4.
    let fen = "4k3/8/8/2KpP3/8/8/8/8 w - d6 0 1";
    assert!(has(fen, "e5d6"));
}

#[test]
fn en_passant_does_not_cure_other_check() {
    // White king on e1 is checked by the rook on e8; ep cannot help.
    let fen = "4r1k1/8/8/3pP3/8/8/8/4K3 w - d6 0 1";
    assert!(!has(fen, "e5d6"));
}

#[test]
fn castling_available() {
    let m = moves("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    assert!(m.contains(&"e1g1".to_string()) && m.contains(&"e1c1".to_string()));
    let m = moves("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1");
    assert!(m.contains(&"e8g8".to_string()) && m.contains(&"e8c8".to_string()));
}

#[test]
fn castling_blocked_or_attacked() {
    // Piece between king and rook.
    assert!(!has("4k3/8/8/8/8/8/8/RN2K2R w KQ - 0 1", "e1c1"));
    assert!(has("4k3/8/8/8/8/8/8/RN2K2R w KQ - 0 1", "e1g1"));
    // Crossed square attacked (rook on f8 covers f1).
    assert!(!has("4kr2/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
    // Landing square attacked.
    assert!(!has("4k1r1/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
    // b1 attacked is fine for queenside castling.
    assert!(has("1r2k3/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1c1"));
    // d1 attacked is not.
    assert!(!has("3rk3/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1c1"));
    // In check: no castling.
    assert!(!has("4r1k1/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
    // An attacked rook does not prevent castling.
    assert!(has("4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
    assert!(has("r3k3/8/8/8/8/8/8/R3K3 w Q - 0 1", "e1c1"));
    assert!(has("4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1", "e1g1"));
}

fn play(fen: &str, uci: &str) -> Position {
    let pos = Position::from_fen(fen).unwrap();
    let mv = pos.legal_moves().iter().copied().find(|m| m.to_string() == uci).unwrap();
    pos.make_move(mv)
}

#[test]
fn castling_rights_lost() {
    let fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1";
    assert_eq!(play(fen, "e1e2").castling().to_string(), "kq"); // king moves
    assert_eq!(play(fen, "e1g1").castling().to_string(), "kq"); // castling
    assert_eq!(play(fen, "h1h2").castling().to_string(), "Qkq"); // h-rook moves
    assert_eq!(play(fen, "a1a2").castling().to_string(), "Kkq"); // a-rook moves
    // Capturing a rook on its corner removes the victim's right.
    assert_eq!(play(fen, "h1h8").castling().to_string(), "Qq");
    assert_eq!(play(fen, "a1a8").castling().to_string(), "Kk");
}

#[test]
fn promotion_capture_on_corner_removes_right() {
    let fen = "r3k2r/1P6/8/8/8/8/8/4K3 w kq - 0 1";
    assert_eq!(play(fen, "b7a8q").castling().to_string(), "k");
    assert_eq!(play(fen, "b7a8n").castling().to_string(), "k");
}

#[test]
fn promotions_generate_four_moves() {
    let m = moves("8/P1k5/K7/8/8/8/8/8 w - - 0 1");
    assert_eq!(m, ["a6a5", "a6b5", "a7a8b", "a7a8n", "a7a8q", "a7a8r"]);
}

#[test]
fn pinned_pieces_stay_on_the_line() {
    // Rook on e2 pinned by the rook on e8: may move along the e-file only.
    let m = moves("4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1");
    for mv in &m {
        if mv.starts_with("e2") {
            assert!(mv.as_bytes()[2] == b'e', "{mv}");
        }
    }
    assert!(m.contains(&"e2e8".to_string()));
    // A pinned knight cannot move at all.
    let m = moves("4r1k1/8/8/8/8/8/4N3/4K3 w - - 0 1");
    assert!(m.iter().all(|mv| !mv.starts_with("e2")));
}

#[test]
fn king_cannot_retreat_along_checking_ray() {
    let m = moves("4k3/8/8/8/8/8/8/r3K3 w - - 0 1");
    assert!(!m.contains(&"e1f1".to_string()) && !m.contains(&"e1d1".to_string()));
    assert!(m.contains(&"e1e2".to_string()));
}

#[test]
fn double_check_allows_only_king_moves() {
    // Knight d3 and rook e8 both give check.
    let m = moves("4r1k1/8/8/8/8/3n4/8/Q3K3 w - - 0 1");
    assert!(m.iter().all(|mv| mv.starts_with("e1")), "{m:?}");
    assert!(!m.is_empty());
}

#[test]
fn single_check_blocks_and_captures() {
    // Rook check on the e-file; the bishop on c3 may block on e5 but not elsewhere.
    let m = moves("4r1k1/8/8/8/8/2B5/8/4K3 w - - 0 1");
    assert!(m.contains(&"c3e5".to_string()));
    assert!(!m.contains(&"c3b4".to_string()));
}

#[test]
fn promotion_perft_known_value() {
    // Promotion-heavy position (Position 4 mirrored) at depth 4.
    let pos = Position::from_fen("r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1")
        .unwrap();
    assert_eq!(perft(&pos, 4), 422_333);
}
