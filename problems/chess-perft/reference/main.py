#!/usr/bin/env python3
"""Reference chess legal move generator with perft and divide.

Board representation: 0x88 mailbox (128-entry list). White pieces are uppercase
letters, black pieces lowercase, empty squares are '.'. Square index = rank*16 +
file, so a square is on the board iff (sq & 0x88) == 0.

Legal move generation uses check and pin information from the king's square so
that only king moves, en passant captures and moves while in check need a full
make-and-test legality check.
"""
import sys

EMPTY = '.'
WHITE, BLACK = 0, 1

N, S, E, W = 16, -16, 1, -1
NE, NW, SE, SW = 17, 15, -15, -17
KNIGHT_OFFS = (33, 31, 18, 14, -33, -31, -18, -14)
KING_OFFS = (N, S, E, W, NE, NW, SE, SW)
BISHOP_DIRS = (NE, NW, SE, SW)
ROOK_DIRS = (N, S, E, W)
QUEEN_DIRS = KING_OFFS

# Castling right bits.
WK, WQ, BK, BQ = 1, 2, 4, 8

A1, B1, C1, D1, E1, F1, G1, H1 = 0, 1, 2, 3, 4, 5, 6, 7
A8, B8, C8, D8, E8, F8, G8, H8 = 112, 113, 114, 115, 116, 117, 118, 119


def sq_name(sq):
    return "abcdefgh"[sq & 7] + str((sq >> 4) + 1)


def parse_sq(s):
    return (int(s[1]) - 1) * 16 + (ord(s[0]) - ord('a'))


def is_white(p):
    return p.isupper()


class Position:
    __slots__ = ("board", "side", "castling", "ep")

    def __init__(self, board, side, castling, ep):
        self.board = board
        self.side = side
        self.castling = castling
        self.ep = ep


def parse_fen(fen_fields):
    board = [EMPTY] * 128
    rows = fen_fields[0].split('/')
    if len(rows) != 8:
        raise ValueError("bad fen board")
    for r, row in enumerate(rows):
        rank = 7 - r
        f = 0
        for ch in row:
            if ch.isdigit():
                f += int(ch)
            else:
                board[rank * 16 + f] = ch
                f += 1
        if f != 8:
            raise ValueError("bad fen row")
    side = WHITE if fen_fields[1] == 'w' else BLACK
    castling = 0
    if fen_fields[2] != '-':
        for ch in fen_fields[2]:
            castling |= {'K': WK, 'Q': WQ, 'k': BK, 'q': BQ}[ch]
    ep = -1 if fen_fields[3] == '-' else parse_sq(fen_fields[3])
    return Position(board, side, castling, ep)


def attacked(board, sq, by_white):
    """True if square sq is attacked by any piece of the given color."""
    if by_white:
        # White pawns attack diagonally upward, so look one rank down from sq.
        for d in (SW, SE):
            t = sq + d
            if not (t & 0x88) and board[t] == 'P':
                return True
        kn, kg, bq, rq = 'N', 'K', ('B', 'Q'), ('R', 'Q')
    else:
        for d in (NW, NE):
            t = sq + d
            if not (t & 0x88) and board[t] == 'p':
                return True
        kn, kg, bq, rq = 'n', 'k', ('b', 'q'), ('r', 'q')
    for d in KNIGHT_OFFS:
        t = sq + d
        if not (t & 0x88) and board[t] == kn:
            return True
    for d in KING_OFFS:
        t = sq + d
        if not (t & 0x88) and board[t] == kg:
            return True
    for d in BISHOP_DIRS:
        t = sq + d
        while not (t & 0x88):
            p = board[t]
            if p != EMPTY:
                if p in bq:
                    return True
                break
            t += d
    for d in ROOK_DIRS:
        t = sq + d
        while not (t & 0x88):
            p = board[t]
            if p != EMPTY:
                if p in rq:
                    return True
                break
            t += d
    return False


def find_king(board, white):
    k = 'K' if white else 'k'
    for sq in range(128):
        if not (sq & 0x88) and board[sq] == k:
            return sq
    raise ValueError("no king")


def ray_dir(a, b):
    """Unit 0x88 step from a to b if they share a rank, file or diagonal, else 0."""
    dr = (b >> 4) - (a >> 4)
    df = (b & 7) - (a & 7)
    if dr == 0 and df == 0:
        return 0
    if dr == 0:
        return E if df > 0 else W
    if df == 0:
        return N if dr > 0 else S
    if dr == df:
        return NE if dr > 0 else SW
    if dr == -df:
        return NW if dr > 0 else SE
    return 0


def make_move(pos, mv):
    """Return the position after playing mv = (from, to, promo_piece_or_None)."""
    frm, to, promo = mv
    board = pos.board[:]
    p = board[frm]
    white = pos.side == WHITE
    castling = pos.castling
    ep = -1
    board[frm] = EMPTY
    captured = board[to]
    if p in 'Pp':
        if to == pos.ep and captured == EMPTY:
            # En passant: remove the pawn that just double-stepped.
            board[to + (S if white else N)] = EMPTY
        elif abs(to - frm) == 32:
            ep = (frm + to) // 2
        if promo:
            p = promo.upper() if white else promo.lower()
    elif p == 'K':
        castling &= ~(WK | WQ)
        if frm == E1 and to == G1:
            board[H1] = EMPTY
            board[F1] = 'R'
        elif frm == E1 and to == C1:
            board[A1] = EMPTY
            board[D1] = 'R'
    elif p == 'k':
        castling &= ~(BK | BQ)
        if frm == E8 and to == G8:
            board[H8] = EMPTY
            board[F8] = 'r'
        elif frm == E8 and to == C8:
            board[A8] = EMPTY
            board[D8] = 'r'
    board[to] = p
    # Any move from or to a rook's home square removes that castling right.
    if frm == H1 or to == H1:
        castling &= ~WK
    if frm == A1 or to == A1:
        castling &= ~WQ
    if frm == H8 or to == H8:
        castling &= ~BK
    if frm == A8 or to == A8:
        castling &= ~BQ
    return Position(board, pos.side ^ 1, castling, ep)


def legal_moves(pos):
    board = pos.board
    white = pos.side == WHITE
    own_upper = white
    ksq = find_king(board, white)
    enemy_white = not white
    in_check = attacked(board, ksq, enemy_white)

    # Pinned pieces: map square -> unit direction of the pin ray from the king.
    pinned = {}
    enemy_bq = ('b', 'q') if white else ('B', 'Q')
    enemy_rq = ('r', 'q') if white else ('R', 'Q')
    for d in QUEEN_DIRS:
        sliders = enemy_bq if d in BISHOP_DIRS else enemy_rq
        t = ksq + d
        blocker = -1
        while not (t & 0x88):
            p = board[t]
            if p != EMPTY:
                if blocker < 0:
                    if is_white(p) == white:
                        blocker = t
                    else:
                        break
                else:
                    if p in sliders:
                        pinned[blocker] = d
                    break
            t += d

    moves = []
    add = moves.append
    pawn = 'P' if white else 'p'
    promo_pieces = ('q', 'r', 'b', 'n')
    fwd = N if white else S
    start_rank = 1 if white else 6
    promo_rank = 7 if white else 0
    ep = pos.ep

    def own(p):
        return p != EMPTY and is_white(p) == own_upper

    def enemy(p):
        return p != EMPTY and is_white(p) != own_upper

    for frm in range(128):
        if frm & 0x88:
            continue
        p = board[frm]
        if p == EMPTY or is_white(p) != own_upper:
            continue
        pt = p.upper()
        pin = pinned.get(frm, 0)
        if pt == 'P':
            to = frm + fwd
            if board[to] == EMPTY and (pin == 0 or pin == fwd or pin == -fwd):
                if (to >> 4) == promo_rank:
                    for pr in promo_pieces:
                        add((frm, to, pr))
                else:
                    add((frm, to, None))
                    to2 = to + fwd
                    if (frm >> 4) == start_rank and board[to2] == EMPTY:
                        add((frm, to2, None))
            for d in ((NW, NE) if white else (SW, SE)):
                to = frm + d
                if to & 0x88:
                    continue
                if pin and pin != d and pin != -d:
                    continue
                if enemy(board[to]):
                    if (to >> 4) == promo_rank:
                        for pr in promo_pieces:
                            add((frm, to, pr))
                    else:
                        add((frm, to, None))
                elif to == ep:
                    # En passant can expose the king along the rank, so test it fully.
                    child = make_move(pos, (frm, to, None))
                    if not attacked(child.board, ksq, enemy_white):
                        add((frm, to, None))
        elif pt == 'N':
            if pin:
                continue
            for d in KNIGHT_OFFS:
                to = frm + d
                if not (to & 0x88) and not own(board[to]):
                    add((frm, to, None))
        elif pt == 'K':
            for d in KING_OFFS:
                to = frm + d
                if (to & 0x88) or own(board[to]):
                    continue
                # Lift the king so sliders see through its origin square.
                board[frm] = EMPTY
                ok = not attacked(board, to, enemy_white)
                board[frm] = p
                if ok:
                    add((frm, to, None))
            if not in_check:
                if white and frm == E1:
                    if (pos.castling & WK) and board[F1] == EMPTY and board[G1] == EMPTY \
                            and board[H1] == 'R' and not attacked(board, F1, enemy_white) \
                            and not attacked(board, G1, enemy_white):
                        add((E1, G1, None))
                    if (pos.castling & WQ) and board[D1] == EMPTY and board[C1] == EMPTY \
                            and board[B1] == EMPTY and board[A1] == 'R' \
                            and not attacked(board, D1, enemy_white) and not attacked(board, C1, enemy_white):
                        add((E1, C1, None))
                elif not white and frm == E8:
                    if (pos.castling & BK) and board[F8] == EMPTY and board[G8] == EMPTY \
                            and board[H8] == 'r' and not attacked(board, F8, enemy_white) \
                            and not attacked(board, G8, enemy_white):
                        add((E8, G8, None))
                    if (pos.castling & BQ) and board[D8] == EMPTY and board[C8] == EMPTY \
                            and board[B8] == EMPTY and board[A8] == 'r' \
                            and not attacked(board, D8, enemy_white) and not attacked(board, C8, enemy_white):
                        add((E8, C8, None))
        else:
            dirs = BISHOP_DIRS if pt == 'B' else ROOK_DIRS if pt == 'R' else QUEEN_DIRS
            for d in dirs:
                if pin and pin != d and pin != -d:
                    continue
                to = frm + d
                while not (to & 0x88):
                    q = board[to]
                    if q == EMPTY:
                        add((frm, to, None))
                    else:
                        if enemy(q):
                            add((frm, to, None))
                        break
                    to += d

    if in_check:
        # Pin logic is not sufficient while in check: every non-king move must
        # resolve the check, so test each candidate by making it.
        filtered = []
        for mv in moves:
            if board[mv[0]] == ('K' if white else 'k'):
                filtered.append(mv)
            else:
                child = make_move(pos, mv)
                if not attacked(child.board, ksq, enemy_white):
                    filtered.append(mv)
        moves = filtered
    return moves


def perft(pos, depth):
    if depth == 0:
        return 1
    moves = legal_moves(pos)
    if depth == 1:
        return len(moves)
    total = 0
    for mv in moves:
        total += perft(make_move(pos, mv), depth - 1)
    return total


def move_uci(mv):
    frm, to, promo = mv
    return sq_name(frm) + sq_name(to) + (promo or '')


def main():
    out = []
    for line in sys.stdin.read().splitlines():
        fields = line.split()
        if not fields:
            continue
        if len(fields) == 8 and fields[6] == 'divide':
            pos = parse_fen(fields[:6])
            depth = int(fields[7])
            results = []
            for mv in legal_moves(pos):
                results.append((move_uci(mv), perft(make_move(pos, mv), depth - 1)))
            results.sort()
            total = 0
            for name, cnt in results:
                out.append(f"{name} {cnt}")
                total += cnt
            out.append(f"total {total}")
        else:
            pos = parse_fen(fields[:6])
            depth = int(fields[6])
            out.append(str(perft(pos, depth)))
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    main()
