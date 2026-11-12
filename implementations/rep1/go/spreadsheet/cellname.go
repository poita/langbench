package spreadsheet

import (
	"fmt"
)

// Sheet limits.
const (
	MaxCol = 702  // columns A..ZZ
	MaxRow = 9999 // rows 1..9999
)

// cellKey packs a (row, col) pair so that sorting keys numerically gives
// row-major order.
type cellKey uint32

func makeKey(row, col int) cellKey { return cellKey(row<<10 | col) }
func (k cellKey) row() int         { return int(k >> 10) }
func (k cellKey) col() int         { return int(k & 1023) }

// String returns the cell name, e.g. "AB12".
func (k cellKey) String() string {
	col := k.col()
	var name []byte
	if col > 26 {
		name = append(name, byte('A'+(col-1)/26-1))
	}
	name = append(name, byte('A'+(col-1)%26))
	return fmt.Sprintf("%s%d", name, k.row())
}

// parseCellName parses a name made of one or two uppercase letters followed by
// a row number 1..9999 without leading zeros.
func parseCellName(s string) (cellKey, bool) {
	i := 0
	for i < len(s) && s[i] >= 'A' && s[i] <= 'Z' {
		i++
	}
	if i < 1 || i > 2 || i == len(s) || len(s)-i > 4 || s[i] == '0' {
		return 0, false
	}
	col := 0
	for _, c := range []byte(s[:i]) {
		col = col*26 + int(c-'A') + 1
	}
	row := 0
	for _, c := range []byte(s[i:]) {
		if c < '0' || c > '9' {
			return 0, false
		}
		row = row*10 + int(c-'0')
	}
	if row < 1 || row > MaxRow {
		return 0, false
	}
	return makeKey(row, col), true
}
