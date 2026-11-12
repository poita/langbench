// Package reedsolomon implements Reed-Solomon error-correction coding over
// GF(2^8) with the QR Code primitive polynomial x^8+x^4+x^3+x^2+1 (0x11D).
package reedsolomon

// primitive is the reduction polynomial of the field, including the x^8 term.
const primitive = 0x11D

var (
	expTable [510]byte // expTable[i] = 2^i; doubled so Mul needs no modulo
	logTable [256]int  // logTable[x] = i such that 2^i = x (x != 0)
)

func init() {
	x := 1
	for i := 0; i < 255; i++ {
		expTable[i] = byte(x)
		expTable[i+255] = byte(x)
		logTable[x] = i
		x <<= 1
		if x >= 256 {
			x ^= primitive
		}
	}
}

// Mul returns the product of a and b in GF(2^8).
func Mul(a, b byte) byte {
	if a == 0 || b == 0 {
		return 0
	}
	return expTable[logTable[a]+logTable[b]]
}

// Generator returns the coefficients of the degree-degree generator polynomial
// prod_{i=0}^{degree-1} (x - 2^i), highest degree first, omitting the leading
// coefficient 1. The result therefore has exactly degree entries.
func Generator(degree int) []byte {
	g := make([]byte, degree)
	g[degree-1] = 1 // the polynomial "1", stored as its low-order coefficients
	root := byte(1)
	for i := 0; i < degree; i++ {
		// Multiply the running polynomial by (x + root).
		for j := 0; j < degree; j++ {
			g[j] = Mul(g[j], root)
			if j+1 < degree {
				g[j] ^= g[j+1]
			}
		}
		root = Mul(root, 2)
	}
	return g
}

// Encoder computes error-correction codewords for a fixed number of ECC
// codewords.
type Encoder struct {
	gen []byte
}

// NewEncoder returns an Encoder producing degree ECC codewords per message.
// degree must be at least 1.
func NewEncoder(degree int) *Encoder {
	return &Encoder{gen: Generator(degree)}
}

// Degree returns the number of ECC codewords the encoder produces.
func (e *Encoder) Degree() int { return len(e.gen) }

// Remainder returns the remainder of data(x)*x^degree divided by the generator
// polynomial: the ECC codewords for data, highest degree first.
func (e *Encoder) Remainder(data []byte) []byte {
	rem := make([]byte, len(e.gen))
	for _, b := range data {
		factor := b ^ rem[0]
		copy(rem, rem[1:])
		rem[len(rem)-1] = 0
		if factor != 0 {
			for i, c := range e.gen {
				rem[i] ^= Mul(c, factor)
			}
		}
	}
	return rem
}
