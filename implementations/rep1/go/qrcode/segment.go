package qrcode

// Mode is a QR Code data encoding mode.
type Mode int

// Encoding modes.
const (
	Numeric Mode = iota
	Alphanumeric
	Byte
)

// String returns the mode's name.
func (m Mode) String() string {
	switch m {
	case Numeric:
		return "numeric"
	case Alphanumeric:
		return "alphanumeric"
	case Byte:
		return "byte"
	}
	return "unknown"
}

// alphanumericChars is the alphanumeric character set; a character's index is
// its value.
const alphanumericChars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

// alnumValue maps a byte to its alphanumeric value, or -1.
var alnumValue [256]int8

func init() {
	for i := range alnumValue {
		alnumValue[i] = -1
	}
	for i := 0; i < len(alphanumericChars); i++ {
		alnumValue[alphanumericChars[i]] = int8(i)
	}
}

// modeIndicator returns the 4-bit mode indicator.
func (m Mode) indicator() uint32 {
	switch m {
	case Numeric:
		return 0x1
	case Alphanumeric:
		return 0x2
	}
	return 0x4
}

// countBits returns the width of the character count indicator.
func (m Mode) countBits(version int) int {
	var w [3]int
	switch m {
	case Numeric:
		w = [3]int{10, 12, 14}
	case Alphanumeric:
		w = [3]int{9, 11, 13}
	default:
		w = [3]int{8, 16, 16}
	}
	switch {
	case version <= 9:
		return w[0]
	case version <= 26:
		return w[1]
	}
	return w[2]
}

// SelectMode returns the most compact applicable mode for data: numeric if all
// bytes are digits, else alphanumeric if all are in the alphanumeric set, else
// byte.
func SelectMode(data []byte) Mode {
	mode := Numeric
	for _, c := range data {
		if c >= '0' && c <= '9' {
			continue
		}
		if alnumValue[c] >= 0 {
			mode = Alphanumeric
			continue
		}
		return Byte
	}
	return mode
}

// dataBits returns the number of data bits (excluding mode indicator and
// character count) for n characters in mode m.
func (m Mode) dataBits(n int) int {
	switch m {
	case Numeric:
		return 10*(n/3) + [3]int{0, 4, 7}[n%3]
	case Alphanumeric:
		return 11*(n/2) + 6*(n%2)
	}
	return 8 * n
}

// bitBuffer is an append-only sequence of bits, most significant bit first.
type bitBuffer struct {
	bytes []byte
	n     int // number of bits
}

// appendBits appends the low width bits of val, most significant first.
func (b *bitBuffer) appendBits(val uint32, width int) {
	for i := width - 1; i >= 0; i-- {
		if b.n%8 == 0 {
			b.bytes = append(b.bytes, 0)
		}
		if val>>uint(i)&1 == 1 {
			b.bytes[b.n/8] |= 0x80 >> uint(b.n%8)
		}
		b.n++
	}
}

// chooseVersion returns the smallest version whose capacity at level holds a
// segment of n characters in mode m, or 0 if none does.
func chooseVersion(m Mode, n int, level Level) int {
	bits := m.dataBits(n)
	for v := MinVersion; v <= MaxVersion; v++ {
		if 4+m.countBits(v)+bits <= DataCapacityBits(v, level) {
			return v
		}
	}
	return 0
}

// encodeSegment writes the mode indicator, character count and data bits of
// data (as a single segment in mode m) for the given version.
func encodeSegment(data []byte, m Mode, version int) *bitBuffer {
	bb := &bitBuffer{bytes: make([]byte, 0, len(data)+8)}
	bb.appendBits(m.indicator(), 4)
	bb.appendBits(uint32(len(data)), m.countBits(version))
	switch m {
	case Numeric:
		for i := 0; i < len(data); i += 3 {
			end := i + 3
			if end > len(data) {
				end = len(data)
			}
			var v uint32
			for _, c := range data[i:end] {
				v = v*10 + uint32(c-'0')
			}
			bb.appendBits(v, [4]int{0, 4, 7, 10}[end-i])
		}
	case Alphanumeric:
		for i := 0; i+1 < len(data); i += 2 {
			bb.appendBits(uint32(alnumValue[data[i]])*45+uint32(alnumValue[data[i+1]]), 11)
		}
		if len(data)%2 == 1 {
			bb.appendBits(uint32(alnumValue[data[len(data)-1]]), 6)
		}
	default:
		for _, c := range data {
			bb.appendBits(uint32(c), 8)
		}
	}
	return bb
}
