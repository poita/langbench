//! Legal move generation driven by check and pin information.
//!
//! For the side to move the generator first computes
//!
//! * the **checkers** of its king, and from them a *check mask* — the squares
//!   a non-king move may land on (everywhere if not in check, the checker plus
//!   the squares between it and the king if in single check, nowhere in
//!   double check);
//! * the **pinned** pieces: own pieces that are the only thing standing
//!   between the king and an enemy slider. A pinned piece may only move along
//!   the line through the king and itself.
//!
//! Ordinary piece, pawn and castling moves are legal by construction once
//! masked with these. Only king moves and en passant captures are verified by
//! asking whether the king would be attacked afterwards.

use crate::attacks::*;
use crate::bitboard::Bitboard;
use crate::moves::{Move, MoveCounter, MoveKind, MoveList, MoveSink};
use crate::position::{Castling, Position};
use crate::types::{Color, PieceKind, Square};

const PROMOTIONS: [PieceKind; 4] =
    [PieceKind::Queen, PieceKind::Rook, PieceKind::Bishop, PieceKind::Knight];

/// Generates every legal move of `pos` into `sink`.
pub fn generate<S: MoveSink>(pos: &Position, sink: &mut S) {
    let us = pos.side_to_move();
    let them = us.opposite();
    let king = pos.king_square(us);
    let occ = pos.occupied();
    let own = pos.by_color(us);
    let enemy = pos.by_color(them);

    let checkers = pos.attackers_to(king, occ, them);
    let n_checkers = checkers.count();

    // En passant is the one non-king move whose legality is tested directly,
    // so it is generated regardless of the check state.
    en_passant(pos, us, them, king, occ, sink);

    // King moves: the destination must not be attacked once the king has left
    // its square (so that it cannot hide "behind" a checking slider).
    let occ_no_king = occ ^ Bitboard::from_square(king);
    for to in king_attacks(king) & !own {
        if pos.attackers_to(to, occ_no_king, them).is_empty() {
            sink.push(Move::new(king, to, MoveKind::Normal));
        }
    }

    if n_checkers >= 2 {
        return;
    }

    let check_mask = match checkers.lsb() {
        Some(c) => between(king, c) | Bitboard::from_square(c),
        None => Bitboard::FULL,
    };

    if checkers.is_empty() {
        castling(pos, us, them, occ, sink);
    }

    let pinned = pinned_pieces(pos, them, king, occ, own);
    let allowed = |sq: Square| -> Bitboard {
        if pinned.contains(sq) { check_mask & line(king, sq) } else { check_mask }
    };

    for kind in [PieceKind::Knight, PieceKind::Bishop, PieceKind::Rook, PieceKind::Queen] {
        for from in pos.pieces(us, kind) {
            let attacks = match kind {
                PieceKind::Knight => knight_attacks(from),
                PieceKind::Bishop => bishop_attacks(from, occ),
                PieceKind::Rook => rook_attacks(from, occ),
                _ => queen_attacks(from, occ),
            };
            sink.push_targets(from, attacks & !own & allowed(from));
        }
    }

    pawn_moves(pos, us, occ, enemy, &allowed, sink);
}

/// Pieces of `us` that are pinned to the king by an enemy slider.
fn pinned_pieces(
    pos: &Position,
    them: Color,
    king: Square,
    occ: Bitboard,
    own: Bitboard,
) -> Bitboard {
    let queens = pos.by_kind(PieceKind::Queen);
    let theirs = pos.by_color(them);
    let snipers = (rook_attacks(king, Bitboard::EMPTY) & (pos.by_kind(PieceKind::Rook) | queens)
        | bishop_attacks(king, Bitboard::EMPTY) & (pos.by_kind(PieceKind::Bishop) | queens))
        & theirs;
    let mut pinned = Bitboard::EMPTY;
    for sniper in snipers {
        let blockers = between(king, sniper) & occ;
        if blockers.count() == 1 && (blockers & own).any() {
            pinned |= blockers;
        }
    }
    pinned
}

/// Pushes the four promotion moves, or the single plain move.
#[inline]
fn push_pawn_move<S: MoveSink>(sink: &mut S, from: Square, to: Square, promotes: bool) {
    if promotes {
        for kind in PROMOTIONS {
            sink.push(Move::new(from, to, MoveKind::Promotion(kind)));
        }
    } else {
        sink.push(Move::new(from, to, MoveKind::Normal));
    }
}

fn pawn_moves<S: MoveSink>(
    pos: &Position,
    us: Color,
    occ: Bitboard,
    enemy: Bitboard,
    allowed: &impl Fn(Square) -> Bitboard,
    sink: &mut S,
) {
    let (forward, start_rank, last_rank): (isize, usize, usize) = match us {
        Color::White => (8, 1, 7),
        Color::Black => (-8, 6, 0),
    };
    for from in pos.pieces(us, PieceKind::Pawn) {
        let mask = allowed(from);
        let one = Square::from_index((from.index() as isize + forward) as usize);
        if !occ.contains(one) {
            if mask.contains(one) {
                push_pawn_move(sink, from, one, one.rank() == last_rank);
            }
            if from.rank() == start_rank {
                let two = Square::from_index((one.index() as isize + forward) as usize);
                if !occ.contains(two) && mask.contains(two) {
                    sink.push(Move::new(from, two, MoveKind::DoublePush));
                }
            }
        }
        for to in pawn_attacks(us, from) & enemy & mask {
            push_pawn_move(sink, from, to, to.rank() == last_rank);
        }
    }
}

/// Generates legal en passant captures, verified by playing them out on the
/// occupancy bitboard.
fn en_passant<S: MoveSink>(
    pos: &Position,
    us: Color,
    them: Color,
    king: Square,
    occ: Bitboard,
    sink: &mut S,
) {
    let Some(ep) = pos.en_passant() else { return };
    let captured = Square::new(ep.file(), match us {
        Color::White => ep.rank() - 1,
        Color::Black => ep.rank() + 1,
    });
    if pos.piece_at(captured) != Some((them, PieceKind::Pawn)) {
        return;
    }
    // Our pawns that attack the ep square are exactly the squares a pawn of
    // the opposite colour on `ep` would attack.
    for from in pawn_attacks(them, ep) & pos.pieces(us, PieceKind::Pawn) {
        let after = (occ ^ Bitboard::from_square(from) ^ Bitboard::from_square(captured))
            | Bitboard::from_square(ep);
        let attackers = pos.attackers_to(king, after, them) & !Bitboard::from_square(captured);
        if attackers.is_empty() {
            sink.push(Move::new(from, ep, MoveKind::EnPassant));
        }
    }
}

fn castling<S: MoveSink>(pos: &Position, us: Color, them: Color, occ: Bitboard, sink: &mut S) {
    let rank = match us {
        Color::White => 0,
        Color::Black => 7,
    };
    let sq = |file| Square::new(file, rank);
    let safe = |file| pos.attackers_to(sq(file), occ, them).is_empty();
    let empty = |files: &[usize]| files.iter().all(|&f| !occ.contains(sq(f)));

    if pos.castling().contains(Castling::kingside(us)) && empty(&[5, 6]) && safe(5) && safe(6) {
        sink.push(Move::new(sq(4), sq(6), MoveKind::Castle));
    }
    if pos.castling().contains(Castling::queenside(us))
        && empty(&[1, 2, 3])
        && safe(3)
        && safe(2)
    {
        sink.push(Move::new(sq(4), sq(2), MoveKind::Castle));
    }
}

impl Position {
    /// All legal moves in this position.
    pub fn legal_moves(&self) -> MoveList {
        let mut list = MoveList::new();
        generate(self, &mut list);
        list
    }

    /// The number of legal moves, counted without materialising them.
    pub fn count_legal_moves(&self) -> u64 {
        let mut counter = MoveCounter::default();
        generate(self, &mut counter);
        counter.count
    }
}
