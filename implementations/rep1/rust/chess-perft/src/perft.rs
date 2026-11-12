//! Perft: counting the leaf nodes of the legal move tree.

use crate::moves::Move;
use crate::position::Position;

/// Counts the leaf nodes of the legal move tree of `pos` at `depth` plies.
///
/// `perft(pos, 0)` is 1. A position with no legal moves (checkmate or
/// stalemate) contributes 0 at any depth of at least 1. At the last ply the
/// legal moves are counted rather than played ("bulk counting").
pub fn perft(pos: &Position, depth: u32) -> u64 {
    match depth {
        0 => 1,
        1 => pos.count_legal_moves(),
        _ => pos
            .legal_moves()
            .iter()
            .map(|&mv| perft(&pos.make_move(mv), depth - 1))
            .sum(),
    }
}

/// Like [`perft`], but reports the count below each root move.
///
/// Each entry is `(move, perft(position after move, depth - 1))`, in
/// generation order (callers wanting UCI order should sort by the move's
/// string). Returns an empty list for `depth == 0`, where there are no
/// moves to report.
pub fn divide(pos: &Position, depth: u32) -> Vec<(Move, u64)> {
    if depth == 0 {
        return Vec::new();
    }
    pos.legal_moves()
        .iter()
        .map(|&mv| (mv, perft(&pos.make_move(mv), depth - 1)))
        .collect()
}
