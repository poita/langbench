package chess

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// ParseFEN parses a FEN record. The halfmove and fullmove fields may be
// omitted (they default to 0 and 1) but are otherwise accepted as given.
//
// ParseFEN checks that the record describes a sane position: exactly one king
// per side, no pawns on the first or last rank, the side not to move is not in
// check, castling rights match the king and rook placement, and the en passant
// square, if any, is plausible. It does not check reachability from the
// starting position.
func ParseFEN(fen string) (*Position, error) {
	fields := strings.Fields(fen)
	if len(fields) != 4 && len(fields) != 6 {
		return nil, fmt.Errorf("chess: FEN %q must have 4 or 6 fields", fen)
	}
	p := &Position{ep: NoSquare, fullmove: 1}

	ranks := strings.Split(fields[0], "/")
	if len(ranks) != 8 {
		return nil, errors.New("chess: FEN placement must have 8 ranks")
	}
	for i, rank := range ranks {
		r, f := 7-i, 0
		for j := 0; j < len(rank); j++ {
			ch := rank[j]
			if ch >= '1' && ch <= '8' {
				f += int(ch - '0')
				continue
			}
			pc, ok := pieceFromChar(ch)
			if !ok {
				return nil, fmt.Errorf("chess: invalid piece %q in FEN", ch)
			}
			if f > 7 {
				return nil, fmt.Errorf("chess: rank %d in FEN is too long", r+1)
			}
			if pc.Type() == Pawn && (r == 0 || r == 7) {
				return nil, errors.New("chess: pawn on first or last rank")
			}
			p.put(NewSquare(f, r), pc)
			f++
		}
		if f != 8 {
			return nil, fmt.Errorf("chess: rank %d in FEN does not have 8 files", r+1)
		}
	}
	for c := White; c <= Black; c++ {
		if p.bb[c][King].Count() != 1 {
			return nil, errors.New("chess: each side must have exactly one king")
		}
	}

	switch fields[1] {
	case "w":
		p.stm = White
	case "b":
		p.stm = Black
	default:
		return nil, fmt.Errorf("chess: invalid side to move %q", fields[1])
	}

	if fields[2] != "-" {
		prev := -1
		for _, ch := range fields[2] {
			i := strings.IndexRune("KQkq", ch)
			if i < 0 || i <= prev {
				return nil, fmt.Errorf("chess: invalid castling field %q", fields[2])
			}
			prev = i
			p.castling |= 1 << uint(i)
		}
	}
	if err := p.checkCastling(); err != nil {
		return nil, err
	}

	if fields[3] != "-" {
		ep, err := ParseSquare(fields[3])
		if err != nil {
			return nil, err
		}
		// The square behind a pawn that just advanced two squares.
		wantRank, pawnSq, pawnColor := 5, ep-8, Black
		if p.stm == Black {
			wantRank, pawnSq, pawnColor = 2, ep+8, White
		}
		if ep.Rank() != wantRank || p.board[ep] != NoPiece || p.board[pawnSq] != NewPiece(pawnColor, Pawn) {
			return nil, fmt.Errorf("chess: invalid en passant square %s", ep)
		}
		p.ep = ep
	}

	if len(fields) == 6 {
		var err error
		if p.halfmove, err = strconv.Atoi(fields[4]); err != nil || p.halfmove < 0 {
			return nil, fmt.Errorf("chess: invalid halfmove clock %q", fields[4])
		}
		if p.fullmove, err = strconv.Atoi(fields[5]); err != nil || p.fullmove < 0 {
			return nil, fmt.Errorf("chess: invalid fullmove number %q", fields[5])
		}
	}

	if p.IsAttacked(p.KingSquare(p.stm.Opposite()), p.stm) {
		return nil, errors.New("chess: side not to move is in check")
	}
	return p, nil
}

// checkCastling verifies every castling right has its king and rook at home.
func (p *Position) checkCastling() error {
	type right struct {
		bit        uint8
		king, rook Square
		color      Color
	}
	for _, r := range []right{
		{CastleWhiteKing, E1, H1, White}, {CastleWhiteQueen, E1, A1, White},
		{CastleBlackKing, E8, H8, Black}, {CastleBlackQueen, E8, A8, Black},
	} {
		if p.castling&r.bit != 0 &&
			(p.board[r.king] != NewPiece(r.color, King) || p.board[r.rook] != NewPiece(r.color, Rook)) {
			return errors.New("chess: castling right without king and rook on their home squares")
		}
	}
	return nil
}

// FEN returns the position as a FEN record.
func (p *Position) FEN() string {
	var sb strings.Builder
	for r := 7; r >= 0; r-- {
		empty := 0
		for f := 0; f < 8; f++ {
			pc := p.board[NewSquare(f, r)]
			if pc == NoPiece {
				empty++
				continue
			}
			if empty > 0 {
				sb.WriteByte(byte('0' + empty))
				empty = 0
			}
			sb.WriteString(pc.String())
		}
		if empty > 0 {
			sb.WriteByte(byte('0' + empty))
		}
		if r > 0 {
			sb.WriteByte('/')
		}
	}
	sb.WriteByte(' ')
	sb.WriteString(p.stm.String())
	sb.WriteByte(' ')
	if p.castling == 0 {
		sb.WriteByte('-')
	} else {
		for i, ch := range "KQkq" {
			if p.castling&(1<<uint(i)) != 0 {
				sb.WriteRune(ch)
			}
		}
	}
	sb.WriteByte(' ')
	sb.WriteString(p.ep.String())
	sb.WriteByte(' ')
	sb.WriteString(strconv.Itoa(p.halfmove))
	sb.WriteByte(' ')
	sb.WriteString(strconv.Itoa(p.fullmove))
	return sb.String()
}
