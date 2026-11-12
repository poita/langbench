"""The mutable :class:`Position`: piece placement, FEN I/O and make/unmake."""

from __future__ import annotations

from .constants import (
    BLACK, CASTLE_BK, CASTLE_BQ, CASTLE_WK, CASTLE_WQ, EMPTY, KING, NO_EP, PAWN,
    PIECE_CHARS, ROOK, WHITE, parse_square, square_name,
)
from .moves import FLAG_CASTLE, FLAG_DOUBLE, FLAG_EN_PASSANT, move_to_uci, uci_to_fields

START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"


class FenError(ValueError):
    """Raised when a FEN string cannot be parsed into a position."""


def _build_castle_keep():
    """``keep[sq]``: castling rights that survive a move from or to ``sq``."""
    keep = [15] * 64
    keep[0] = 15 ^ CASTLE_WQ
    keep[7] = 15 ^ CASTLE_WK
    keep[4] = 15 ^ (CASTLE_WK | CASTLE_WQ)
    keep[56] = 15 ^ CASTLE_BQ
    keep[63] = 15 ^ CASTLE_BK
    keep[60] = 15 ^ (CASTLE_BK | CASTLE_BQ)
    return keep


_CASTLE_KEEP = _build_castle_keep()


class Position:
    """A chess position that is changed in place by :meth:`make` / :meth:`unmake`.

    Attributes (all treated as read-only by callers):

    ``pcs``
        ``pcs[colour][piece_type]`` is the bitboard of that piece kind.
    ``occ``
        ``occ[colour]`` is the bitboard of all pieces of a colour.
    ``board``
        64-entry mailbox: piece type (``PAWN``..``KING``) or ``EMPTY``.
    ``stm``
        Side to move (``WHITE`` or ``BLACK``).
    ``castling``
        Bit set of ``CASTLE_*`` rights.
    ``ep``
        En passant target square, or ``NO_EP``.

    The half-move clock and move number of a FEN record are not kept: no
    fifty-move or repetition rule is implemented.
    """

    __slots__ = ("pcs", "occ", "board", "stm", "castling", "ep")

    def __init__(self):
        self.pcs = [[0] * 6, [0] * 6]
        self.occ = [0, 0]
        self.board = [EMPTY] * 64
        self.stm = WHITE
        self.castling = 0
        self.ep = NO_EP

    # ------------------------------------------------------------------ FEN
    @classmethod
    def from_fen(cls, fen: str) -> "Position":
        """Parse a FEN record.

        The half-move and full-move fields may be omitted and are ignored.
        Castling rights whose king or rook is not on its home square are
        dropped.  The position is otherwise assumed legal (one king per side,
        side not to move not in check); only the first of these is checked.

        Raises :class:`FenError` on malformed input.
        """
        fields = fen.split()
        if len(fields) not in (4, 5, 6):
            raise FenError(f"expected 4 to 6 FEN fields, got {len(fields)}")
        placement, side, castling, ep = fields[:4]
        for counter in fields[4:]:
            if not counter.isdigit():
                raise FenError(f"invalid move counter: {counter!r}")

        pos = cls()
        ranks = placement.split("/")
        if len(ranks) != 8:
            raise FenError("placement must have 8 ranks")
        for i, rank in enumerate(ranks):
            file = 0
            for ch in rank:
                if ch in "12345678":
                    file += int(ch)
                    continue
                lower = ch.lower()
                if lower not in PIECE_CHARS or file > 7:
                    raise FenError(f"invalid placement: {placement!r}")
                colour = WHITE if ch.isupper() else BLACK
                pos._put(colour, PIECE_CHARS.index(lower), (7 - i) * 8 + file)
                file += 1
            if file != 8:
                raise FenError(f"rank does not span 8 files: {rank!r}")
        for colour in (WHITE, BLACK):
            if pos.pcs[colour][KING].bit_count() != 1:
                raise FenError("each side needs exactly one king")

        if side not in ("w", "b"):
            raise FenError(f"invalid side to move: {side!r}")
        pos.stm = WHITE if side == "w" else BLACK

        if castling != "-":
            if not castling or any(c not in "KQkq" for c in castling) or len(set(castling)) != len(castling):
                raise FenError(f"invalid castling field: {castling!r}")
            for ch, bit, king, rook, colour in (
                ("K", CASTLE_WK, 4, 7, WHITE), ("Q", CASTLE_WQ, 4, 0, WHITE),
                ("k", CASTLE_BK, 60, 63, BLACK), ("q", CASTLE_BQ, 60, 56, BLACK),
            ):
                if ch in castling and pos._is(colour, KING, king) and pos._is(colour, ROOK, rook):
                    pos.castling |= bit

        if ep != "-":
            try:
                sq = parse_square(ep)
            except ValueError as exc:
                raise FenError(str(exc)) from None
            # Keep it only if it is consistent with a pawn that just advanced.
            if pos.stm == WHITE:
                ok = sq >> 3 == 5 and pos._is(BLACK, PAWN, sq - 8)
            else:
                ok = sq >> 3 == 2 and pos._is(WHITE, PAWN, sq + 8)
            if ok and pos.board[sq] == EMPTY:
                pos.ep = sq
        return pos

    def to_fen(self) -> str:
        """Return the FEN record (the counters are written as ``0 1``)."""
        rows = []
        for rank in range(7, -1, -1):
            row, gap = "", 0
            for file in range(8):
                sq = rank * 8 + file
                pt = self.board[sq]
                if pt == EMPTY:
                    gap += 1
                    continue
                if gap:
                    row += str(gap)
                    gap = 0
                ch = PIECE_CHARS[pt]
                row += ch.upper() if self.occ[WHITE] >> sq & 1 else ch
            rows.append(row + (str(gap) if gap else ""))
        castling = "".join(c for c, b in zip("KQkq", (1, 2, 4, 8)) if self.castling & b) or "-"
        ep = square_name(self.ep) if self.ep != NO_EP else "-"
        return f"{'/'.join(rows)} {'w' if self.stm == WHITE else 'b'} {castling} {ep} 0 1"

    def _put(self, colour, piece, sq):
        bit = 1 << sq
        self.pcs[colour][piece] |= bit
        self.occ[colour] |= bit
        self.board[sq] = piece

    def _is(self, colour, piece, sq):
        return bool(self.pcs[colour][piece] >> sq & 1)

    # --------------------------------------------------------------- queries
    def copy(self) -> "Position":
        """Return an independent copy of this position."""
        other = Position.__new__(Position)
        other.pcs = [self.pcs[0][:], self.pcs[1][:]]
        other.occ = self.occ[:]
        other.board = self.board[:]
        other.stm = self.stm
        other.castling = self.castling
        other.ep = self.ep
        return other

    def king_square(self, colour: int) -> int:
        """Square of ``colour``'s king."""
        return self.pcs[colour][KING].bit_length() - 1

    def legal_moves(self) -> list[int]:
        """All legal moves of the side to move, as packed ints (see :mod:`moves`)."""
        from .movegen import generate_legal_moves

        return generate_legal_moves(self)

    def legal_move_count(self) -> int:
        """Number of legal moves, counted without generating them one by one."""
        from .movegen import count_legal_moves

        return count_legal_moves(self)

    def in_check(self) -> bool:
        """Whether the side to move is in check."""
        from .movegen import is_attacked

        return is_attacked(self, self.king_square(self.stm), self.stm ^ 1)

    def parse_uci(self, text: str) -> int:
        """Return the legal move written ``text`` in UCI notation.

        Raises :class:`ValueError` if it is not legal in this position.
        """
        origin, target, promo = uci_to_fields(text)
        for move in self.legal_moves():
            if move & 63 == origin and move >> 6 & 63 == target and move >> 12 & 7 == promo:
                return move
        raise ValueError(f"illegal move: {text!r}")

    def uci_moves(self) -> list[str]:
        """Legal moves as sorted UCI strings."""
        return sorted(move_to_uci(m) for m in self.legal_moves())

    # ------------------------------------------------------ make / unmake
    def make(self, move: int):
        """Play a (legal) move in place and return an undo token for :meth:`unmake`."""
        us = self.stm
        them = us ^ 1
        frm = move & 63
        to = move >> 6 & 63
        promo = move >> 12 & 7
        flag = move >> 15
        fb = 1 << frm
        tb = 1 << to
        ft = fb | tb
        board = self.board
        occ = self.occ
        mine = self.pcs[us]
        captured = board[to]
        undo = (captured, self.castling, self.ep)
        pt = board[frm]
        board[frm] = EMPTY
        if promo:
            mine[PAWN] ^= fb
            mine[promo] ^= tb
            board[to] = promo
        else:
            mine[pt] ^= ft
            board[to] = pt
        occ[us] ^= ft
        if captured != EMPTY:
            self.pcs[them][captured] ^= tb
            occ[them] ^= tb
        self.castling &= _CASTLE_KEEP[frm] & _CASTLE_KEEP[to]
        self.ep = NO_EP
        if flag:
            if flag == FLAG_DOUBLE:
                self.ep = frm + to >> 1
            elif flag == FLAG_EN_PASSANT:
                cs = to - 8 if us == WHITE else to + 8
                cb = 1 << cs
                self.pcs[them][PAWN] ^= cb
                occ[them] ^= cb
                board[cs] = EMPTY
            else:  # castling: move the rook
                if to > frm:
                    rf, rt = frm + 3, frm + 1
                else:
                    rf, rt = frm - 4, frm - 1
                rb = 1 << rf | 1 << rt
                mine[ROOK] ^= rb
                occ[us] ^= rb
                board[rf] = EMPTY
                board[rt] = ROOK
        self.stm = them
        return undo

    def unmake(self, move: int, undo) -> None:
        """Take back ``move``, the most recent :meth:`make`, given its undo token."""
        captured, castling, ep = undo
        them = self.stm
        us = them ^ 1
        frm = move & 63
        to = move >> 6 & 63
        promo = move >> 12 & 7
        flag = move >> 15
        fb = 1 << frm
        tb = 1 << to
        ft = fb | tb
        board = self.board
        occ = self.occ
        mine = self.pcs[us]
        if promo:
            mine[PAWN] ^= fb
            mine[promo] ^= tb
            board[frm] = PAWN
        else:
            pt = board[to]
            mine[pt] ^= ft
            board[frm] = pt
        occ[us] ^= ft
        board[to] = captured
        if captured != EMPTY:
            self.pcs[them][captured] ^= tb
            occ[them] ^= tb
        if flag:
            if flag == FLAG_EN_PASSANT:
                cs = to - 8 if us == WHITE else to + 8
                cb = 1 << cs
                self.pcs[them][PAWN] ^= cb
                occ[them] ^= cb
                board[cs] = PAWN
            elif flag == FLAG_CASTLE:
                if to > frm:
                    rf, rt = frm + 3, frm + 1
                else:
                    rf, rt = frm - 4, frm - 1
                rb = 1 << rf | 1 << rt
                mine[ROOK] ^= rb
                occ[us] ^= rb
                board[rf] = ROOK
                board[rt] = EMPTY
        self.castling = castling
        self.ep = ep
        self.stm = us

    def __repr__(self) -> str:
        return f"Position({self.to_fen()!r})"

    def __eq__(self, other) -> bool:
        if not isinstance(other, Position):
            return NotImplemented
        return (
            self.pcs == other.pcs and self.stm == other.stm
            and self.castling == other.castling and self.ep == other.ep
        )

    __hash__ = None  # mutable
