package qr

// Mode is a QR data encoding mode.
type Mode int

// Supported encoding modes.
const (
	Numeric Mode = iota
	Alphanumeric
	Byte
)

// String returns the mode name.
func (m Mode) String() string {
	switch m {
	case Numeric:
		return "numeric"
	case Alphanumeric:
		return "alphanumeric"
	}
	return "byte"
}

const alnumChars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

// alnumVal maps a byte to its alphanumeric value, or -1.
var alnumVal [256]int8

func init() {
	for i := range alnumVal {
		alnumVal[i] = -1
	}
	for i := 0; i < len(alnumChars); i++ {
		alnumVal[alnumChars[i]] = int8(i)
	}
}

// SelectMode returns the most compact mode able to represent data.
func SelectMode(data []byte) Mode {
	numeric := true
	for _, b := range data {
		if alnumVal[b] < 0 {
			return Byte
		}
		if b > '9' || b < '0' {
			numeric = false
		}
	}
	if numeric {
		return Numeric
	}
	return Alphanumeric
}

// modeBits is the 4-bit mode indicator.
func modeBits(m Mode) uint32 {
	switch m {
	case Numeric:
		return 1
	case Alphanumeric:
		return 2
	}
	return 4
}

// countBits returns the character count indicator width.
func countBits(m Mode, v int) uint {
	idx := 0
	if v >= 27 {
		idx = 2
	} else if v >= 10 {
		idx = 1
	}
	return [3][3]uint{{10, 12, 14}, {9, 11, 13}, {8, 16, 16}}[m][idx]
}

// dataBitLen returns the payload bit length for n characters in mode m.
func dataBitLen(m Mode, n int) int {
	switch m {
	case Numeric:
		return 10*(n/3) + [3]int{0, 4, 7}[n%3]
	case Alphanumeric:
		return 11*(n/2) + 6*(n%2)
	}
	return 8 * n
}

// chooseVersion returns the smallest version at level ecl that can hold n
// characters in mode m, or 0 if none can.
func chooseVersion(m Mode, n int, ecl ECL) int {
	bits := dataBitLen(m, n)
	for v := MinVersion; v <= MaxVersion; v++ {
		if 4+int(countBits(m, v))+bits <= 8*dataCodewords(v, ecl) {
			return v
		}
	}
	return 0
}
