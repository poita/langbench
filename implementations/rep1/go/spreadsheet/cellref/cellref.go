// Package cellref parses and formats spreadsheet cell names such as "A1" or
// "ZZ9999".
//
// A cell name is one or two uppercase ASCII letters (the column, 1..702)
// followed by a row number 1..9999 written without leading zeros. Cells are
// also identified by an integer key whose numeric order is row-major order.
package cellref

const (
	// MaxCol is the largest column number (ZZ).
	MaxCol = 702
	// MaxRow is the largest row number.
	MaxRow = 9999
	// Stride is the multiplier used to combine a row and a column into a key.
	Stride = MaxCol + 1
)

// Key combines a column (1..MaxCol) and a row (1..MaxRow) into an integer
// whose numeric order is row-major order.
func Key(col, row int) int { return row*Stride + col }

// Split is the inverse of Key.
func Split(key int) (col, row int) { return key % Stride, key / Stride }

// Parse parses a complete cell name. It reports ok == false if s is not a
// valid cell name (too many letters, no digits, row out of range, leading
// zero in the row, trailing garbage, ...).
func Parse(s string) (col, row int, ok bool) {
	i := 0
	for i < len(s) && s[i] >= 'A' && s[i] <= 'Z' {
		col = col*26 + int(s[i]-'A') + 1
		i++
	}
	if i == 0 || i > 2 {
		return 0, 0, false
	}
	digits := s[i:]
	if len(digits) == 0 || len(digits) > 4 || digits[0] == '0' {
		return 0, 0, false
	}
	for j := 0; j < len(digits); j++ {
		c := digits[j]
		if c < '0' || c > '9' {
			return 0, 0, false
		}
		row = row*10 + int(c-'0')
	}
	if row < 1 || row > MaxRow {
		return 0, 0, false
	}
	return col, row, true
}

// ParseKey is like Parse but returns the cell key.
func ParseKey(s string) (key int, ok bool) {
	col, row, ok := Parse(s)
	if !ok {
		return 0, false
	}
	return Key(col, row), true
}

// Append appends the name of the cell at (col, row) to dst.
func Append(dst []byte, col, row int) []byte {
	if col > 26 {
		dst = append(dst, byte('A'+(col-1)/26-1))
	}
	dst = append(dst, byte('A'+(col-1)%26))
	return appendInt(dst, row)
}

// Name returns the name of the cell at (col, row).
func Name(col, row int) string { return string(Append(nil, col, row)) }

func appendInt(dst []byte, n int) []byte {
	var tmp [5]byte
	i := len(tmp)
	for {
		i--
		tmp[i] = byte('0' + n%10)
		n /= 10
		if n == 0 {
			break
		}
	}
	return append(dst, tmp[i:]...)
}
