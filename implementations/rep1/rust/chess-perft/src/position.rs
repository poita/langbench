//! The board state: FEN parsing, piece queries and move making.

use crate::attacks::*;
use crate::bitboard::Bitboard;
use crate::error::ParseError;
use crate::moves::{Move, MoveKind};
use crate::types::{Color, PieceKind, Square};
use std::fmt;

/// Castling rights as a 4-bit set.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct Castling(u8);

impl Castling {
    /// No rights.
    pub const NONE: Castling = Castling(0);
    /// White may castle kingside.
    pub const WHITE_KING: Castling = Castling(1);
    /// White may castle queenside.
    pub const WHITE_QUEEN: Castling = Castling(2);
    /// Black may castle kingside.
    pub const BLACK_KING: Castling = Castling(4);
    /// Black may castle queenside.
    pub const BLACK_QUEEN: Castling = Castling(8);

    /// True if every right in `other` is present.
    #[inline]
    pub const fn contains(self, other: Castling) -> bool {
        self.0 & other.0 == other.0
    }

    /// Union of two sets of rights.
    #[inline]
    pub const fn union(self, other: Castling) -> Castling {
        Castling(self.0 | other.0)
    }

    /// Intersection of two sets of rights.
    #[inline]
    pub const fn intersect(self, other: Castling) -> Castling {
        Castling(self.0 & other.0)
    }

    /// The kingside right of `color`.
    #[inline]
    pub const fn kingside(color: Color) -> Castling {
        match color {
            Color::White => Castling::WHITE_KING,
            Color::Black => Castling::BLACK_KING,
        }
    }

    /// The queenside right of `color`.
    #[inline]
    pub const fn queenside(color: Color) -> Castling {
        match color {
            Color::White => Castling::WHITE_QUEEN,
            Color::Black => Castling::BLACK_QUEEN,
        }
    }
}

impl fmt::Display for Castling {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0 == 0 {
            return write!(f, "-");
        }
        for (flag, c) in [
            (Castling::WHITE_KING, 'K'),
            (Castling::WHITE_QUEEN, 'Q'),
            (Castling::BLACK_KING, 'k'),
            (Castling::BLACK_QUEEN, 'q'),
        ] {
            if self.contains(flag) {
                write!(f, "{c}")?;
            }
        }
        Ok(())
    }
}

/// Rights that survive a move touching each square (king/rook home squares
/// clear the relevant rights, whether the piece leaves or is captured there).
const CASTLE_KEEP: [u8; 64] = {
    let mut t = [15u8; 64];
    t[0] = 15 & !2; // a1
    t[7] = 15 & !1; // h1
    t[4] = 15 & !3; // e1
    t[56] = 15 & !8; // a8
    t[63] = 15 & !4; // h8
    t[60] = 15 & !12; // e8
    t
};

/// A chess position.
///
/// `Position` is a small `Copy` value; [`Position::make_move`] returns a new
/// position rather than mutating in place. The halfmove clock and fullmove
/// number of a FEN record are accepted but not stored, since no rule in this
/// crate depends on them.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Position {
    pieces: [Bitboard; 6],
    colors: [Bitboard; 2],
    board: [Option<PieceKind>; 64],
    side: Color,
    castling: Castling,
    ep: Option<Square>,
}

impl Position {
    /// FEN of the standard starting position.
    pub const START_FEN: &'static str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

    /// The standard starting position.
    pub fn startpos() -> Position {
        Position::from_fen(Self::START_FEN).expect("start FEN is valid")
    }

    /// Parses a FEN record.
    ///
    /// All six fields are accepted; the halfmove and fullmove fields may be
    /// omitted and are ignored. Castling rights whose king or rook is not on
    /// its home square are dropped.
    pub fn from_fen(fen: &str) -> Result<Position, ParseError> {
        let fields: Vec<&str> = fen.split_whitespace().collect();
        if !(4..=6).contains(&fields.len()) {
            return Err(ParseError::FieldCount(fields.len()));
        }
        let mut pos = Position {
            pieces: [Bitboard::EMPTY; 6],
            colors: [Bitboard::EMPTY; 2],
            board: [None; 64],
            side: Color::White,
            castling: Castling::NONE,
            ep: None,
        };

        let ranks: Vec<&str> = fields[0].split('/').collect();
        if ranks.len() != 8 {
            return Err(ParseError::Placement(format!("expected 8 ranks, got {}", ranks.len())));
        }
        for (i, rank_str) in ranks.iter().enumerate() {
            let rank = 7 - i;
            let mut file = 0usize;
            for c in rank_str.chars() {
                if let Some(d) = c.to_digit(10) {
                    if !(1..=8).contains(&d) {
                        return Err(ParseError::Placement(format!("bad digit {c}")));
                    }
                    file += d as usize;
                } else if let Some((color, kind)) = PieceKind::from_fen_char(c) {
                    if file >= 8 {
                        return Err(ParseError::Placement(format!("rank too long: {rank_str}")));
                    }
                    pos.put(color, kind, Square::new(file, rank));
                    file += 1;
                } else {
                    return Err(ParseError::Placement(format!("bad character {c:?}")));
                }
            }
            if file != 8 {
                return Err(ParseError::Placement(format!("rank has {file} files: {rank_str}")));
            }
        }
        for color in [Color::White, Color::Black] {
            if (pos.pieces[PieceKind::King.index()] & pos.colors[color.index()]).count() != 1 {
                return Err(ParseError::Kings);
            }
        }

        pos.side = match fields[1] {
            "w" => Color::White,
            "b" => Color::Black,
            s => return Err(ParseError::Side(s.to_string())),
        };

        if fields[2] != "-" {
            for c in fields[2].chars() {
                pos.castling = pos.castling.union(match c {
                    'K' => Castling::WHITE_KING,
                    'Q' => Castling::WHITE_QUEEN,
                    'k' => Castling::BLACK_KING,
                    'q' => Castling::BLACK_QUEEN,
                    _ => return Err(ParseError::Castling(fields[2].to_string())),
                });
            }
        }
        pos.sanitize_castling();

        if fields[3] != "-" {
            let sq = Square::parse(fields[3])
                .map_err(|_| ParseError::EnPassant(fields[3].to_string()))?;
            pos.ep = Some(sq);
        }

        for f in &fields[4..] {
            f.parse::<u32>().map_err(|_| ParseError::Number(f.to_string()))?;
        }
        Ok(pos)
    }

    /// Drops castling rights that are not backed by a king and rook on their
    /// home squares.
    fn sanitize_castling(&mut self) {
        let checks = [
            (Castling::WHITE_KING, Color::White, "e1", "h1"),
            (Castling::WHITE_QUEEN, Color::White, "e1", "a1"),
            (Castling::BLACK_KING, Color::Black, "e8", "h8"),
            (Castling::BLACK_QUEEN, Color::Black, "e8", "a8"),
        ];
        for (flag, color, k, r) in checks {
            let (k, r) = (Square::parse(k).unwrap(), Square::parse(r).unwrap());
            let ok = self.piece_at(k) == Some((color, PieceKind::King))
                && self.piece_at(r) == Some((color, PieceKind::Rook));
            if !ok {
                self.castling = Castling(self.castling.0 & !flag.0);
            }
        }
    }

    /// Renders the position as FEN (halfmove clock `0`, fullmove number `1`).
    pub fn to_fen(&self) -> String {
        let mut s = String::new();
        for rank in (0..8).rev() {
            let mut empty = 0;
            for file in 0..8 {
                match self.piece_at(Square::new(file, rank)) {
                    None => empty += 1,
                    Some((color, kind)) => {
                        if empty > 0 {
                            s.push_str(&empty.to_string());
                            empty = 0;
                        }
                        let c = kind.to_char();
                        s.push(if color == Color::White { c.to_ascii_uppercase() } else { c });
                    }
                }
            }
            if empty > 0 {
                s.push_str(&empty.to_string());
            }
            if rank > 0 {
                s.push('/');
            }
        }
        let side = if self.side == Color::White { 'w' } else { 'b' };
        let ep = self.ep.map_or("-".to_string(), |sq| sq.to_string());
        format!("{s} {side} {} {ep} 0 1", self.castling)
    }

    /// The side to move.
    #[inline]
    pub fn side_to_move(&self) -> Color {
        self.side
    }

    /// Current castling rights.
    #[inline]
    pub fn castling(&self) -> Castling {
        self.castling
    }

    /// The en passant target square, if any.
    #[inline]
    pub fn en_passant(&self) -> Option<Square> {
        self.ep
    }

    /// All squares occupied by either side.
    #[inline]
    pub fn occupied(&self) -> Bitboard {
        self.colors[0] | self.colors[1]
    }

    /// Squares occupied by `color`.
    #[inline]
    pub fn by_color(&self, color: Color) -> Bitboard {
        self.colors[color.index()]
    }

    /// Squares occupied by pieces of `kind` (either colour).
    #[inline]
    pub fn by_kind(&self, kind: PieceKind) -> Bitboard {
        self.pieces[kind.index()]
    }

    /// Squares occupied by pieces of `kind` and `color`.
    #[inline]
    pub fn pieces(&self, color: Color, kind: PieceKind) -> Bitboard {
        self.pieces[kind.index()] & self.colors[color.index()]
    }

    /// The piece kind on `sq`, if any.
    #[inline]
    pub fn kind_at(&self, sq: Square) -> Option<PieceKind> {
        self.board[sq.index()]
    }

    /// The colour and kind of the piece on `sq`, if any.
    pub fn piece_at(&self, sq: Square) -> Option<(Color, PieceKind)> {
        let kind = self.board[sq.index()]?;
        let color = if self.colors[0].contains(sq) { Color::White } else { Color::Black };
        Some((color, kind))
    }

    /// The square of `color`'s king.
    #[inline]
    pub fn king_square(&self, color: Color) -> Square {
        self.pieces(color, PieceKind::King).lsb().expect("position has a king")
    }

    /// Pieces of colour `by` that attack `sq`, given occupancy `occ`.
    ///
    /// Passing an occupancy different from [`Position::occupied`] lets callers
    /// ask "what if this piece were not there"; pieces missing from `occ` are
    /// *not* removed from the result, so callers must mask them themselves.
    #[inline]
    pub fn attackers_to(&self, sq: Square, occ: Bitboard, by: Color) -> Bitboard {
        let theirs = self.colors[by.index()];
        let diag = self.pieces[PieceKind::Bishop.index()] | self.pieces[PieceKind::Queen.index()];
        let orth = self.pieces[PieceKind::Rook.index()] | self.pieces[PieceKind::Queen.index()];
        (pawn_attacks(by.opposite(), sq) & self.pieces[PieceKind::Pawn.index()]
            | knight_attacks(sq) & self.pieces[PieceKind::Knight.index()]
            | king_attacks(sq) & self.pieces[PieceKind::King.index()]
            | bishop_attacks(sq, occ) & diag
            | rook_attacks(sq, occ) & orth)
            & theirs
    }

    /// True if the side to move is in check.
    pub fn in_check(&self) -> bool {
        self.attackers_to(self.king_square(self.side), self.occupied(), self.side.opposite()).any()
    }

    fn put(&mut self, color: Color, kind: PieceKind, sq: Square) {
        let bb = Bitboard::from_square(sq);
        self.pieces[kind.index()] |= bb;
        self.colors[color.index()] |= bb;
        self.board[sq.index()] = Some(kind);
    }

    fn remove(&mut self, color: Color, kind: PieceKind, sq: Square) {
        let bb = Bitboard::from_square(sq);
        self.pieces[kind.index()] ^= bb;
        self.colors[color.index()] ^= bb;
        self.board[sq.index()] = None;
    }

    /// Plays a legal move and returns the resulting position.
    ///
    /// The move must be legal in this position (for example, one produced by
    /// [`Position::legal_moves`]); otherwise the result is unspecified and may
    /// panic.
    pub fn make_move(&self, mv: Move) -> Position {
        let mut p = *self;
        let us = self.side;
        let them = us.opposite();
        let moving = self.board[mv.from.index()].expect("move from an empty square");

        if mv.kind == MoveKind::EnPassant {
            let cap = Square::new(mv.to.file(), mv.from.rank());
            p.remove(them, PieceKind::Pawn, cap);
        } else if let Some(captured) = self.board[mv.to.index()] {
            p.remove(them, captured, mv.to);
        }

        p.remove(us, moving, mv.from);
        let placed = match mv.kind {
            MoveKind::Promotion(k) => k,
            _ => moving,
        };
        p.put(us, placed, mv.to);

        if mv.kind == MoveKind::Castle {
            let rank = mv.from.rank();
            let (rook_from, rook_to) = if mv.to.file() > mv.from.file() {
                (Square::new(7, rank), Square::new(5, rank))
            } else {
                (Square::new(0, rank), Square::new(3, rank))
            };
            p.remove(us, PieceKind::Rook, rook_from);
            p.put(us, PieceKind::Rook, rook_to);
        }

        p.castling = Castling(p.castling.0 & CASTLE_KEEP[mv.from.index()] & CASTLE_KEEP[mv.to.index()]);
        p.ep = if mv.kind == MoveKind::DoublePush {
            Some(Square::new(mv.from.file(), (mv.from.rank() + mv.to.rank()) / 2))
        } else {
            None
        };
        p.side = them;
        p
    }
}

impl fmt::Display for Position {
    /// Prints the FEN of the position.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_fen())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sq(s: &str) -> Square {
        Square::parse(s).unwrap()
    }

    #[test]
    fn startpos_layout() {
        let p = Position::startpos();
        assert_eq!(p.occupied().count(), 32);
        assert_eq!(p.piece_at(sq("e1")), Some((Color::White, PieceKind::King)));
        assert_eq!(p.piece_at(sq("d8")), Some((Color::Black, PieceKind::Queen)));
        assert_eq!(p.piece_at(sq("e4")), None);
        assert_eq!(p.side_to_move(), Color::White);
        assert_eq!(p.castling().to_string(), "KQkq");
        assert!(!p.in_check());
    }

    #[test]
    fn fen_roundtrip() {
        for fen in [
            Position::START_FEN,
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
            "8/P1k5/K7/8/8/8/8/8 w - - 0 1",
        ] {
            let p = Position::from_fen(fen).unwrap();
            let q = Position::from_fen(&p.to_fen()).unwrap();
            assert_eq!(p, q);
        }
        assert_eq!(Position::startpos().to_fen(), Position::START_FEN);
    }

    #[test]
    fn rejects_bad_fen() {
        assert!(Position::from_fen("").is_err());
        assert!(Position::from_fen("8/8/8/8/8/8/8 w - - 0 1").is_err());
        assert!(Position::from_fen("8/8/8/8/8/8/8/8 w - - 0 1").is_err()); // no kings
        assert!(Position::from_fen("4k3/8/8/8/8/8/8/4K3 x - - 0 1").is_err());
        assert!(Position::from_fen("4k3/8/8/8/8/8/8/4K3 w Z - 0 1").is_err());
        assert!(Position::from_fen("4k3/8/8/8/8/8/8/4K3 w - e9 0 1").is_err());
        assert!(Position::from_fen("4k3/9/8/8/8/8/8/4K3 w - - 0 1").is_err());
    }

    #[test]
    fn castling_without_pieces_is_dropped() {
        let p = Position::from_fen("4k3/8/8/8/8/8/8/4K3 w KQkq - 0 1").unwrap();
        assert_eq!(p.castling(), Castling::NONE);
    }

    #[test]
    fn make_move_updates_state() {
        let p = Position::startpos();
        let q = p.make_move(Move::new(sq("e2"), sq("e4"), MoveKind::DoublePush));
        assert_eq!(q.side_to_move(), Color::Black);
        assert_eq!(q.en_passant(), Some(sq("e3")));
        assert_eq!(q.piece_at(sq("e4")), Some((Color::White, PieceKind::Pawn)));
        assert_eq!(q.piece_at(sq("e2")), None);
        let r = q.make_move(Move::new(sq("g8"), sq("f6"), MoveKind::Normal));
        assert_eq!(r.en_passant(), None);
    }

    #[test]
    fn castling_moves_rook_and_clears_rights() {
        let p = Position::from_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1").unwrap();
        let q = p.make_move(Move::new(sq("e1"), sq("g1"), MoveKind::Castle));
        assert_eq!(q.piece_at(sq("f1")), Some((Color::White, PieceKind::Rook)));
        assert_eq!(q.piece_at(sq("h1")), None);
        assert_eq!(q.castling().to_string(), "kq");
        let r = q.make_move(Move::new(sq("e8"), sq("c8"), MoveKind::Castle));
        assert_eq!(r.piece_at(sq("d8")), Some((Color::Black, PieceKind::Rook)));
        assert_eq!(r.piece_at(sq("a8")), None);
        assert_eq!(r.castling(), Castling::NONE);
    }

    #[test]
    fn capturing_a_corner_rook_clears_right() {
        let p = Position::from_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1").unwrap();
        let q = p.make_move(Move::new(sq("a1"), sq("a8"), MoveKind::Normal));
        assert_eq!(q.castling().to_string(), "Kk");
    }

    #[test]
    fn en_passant_removes_pawn() {
        let p = Position::from_fen("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1").unwrap();
        let q = p.make_move(Move::new(sq("e5"), sq("d6"), MoveKind::EnPassant));
        assert_eq!(q.piece_at(sq("d5")), None);
        assert_eq!(q.piece_at(sq("d6")), Some((Color::White, PieceKind::Pawn)));
    }
}
