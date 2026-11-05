package qr

// GF(2^8) with primitive polynomial x^8+x^4+x^3+x^2+1 (0x11D) and generator 2.
var (
	gfExp [512]byte // gfExp[i] = 2^i, doubled so products need no modulo
	gfLog [256]byte // gfLog[x] = discrete log of x (gfLog[0] unused)
)

func init() {
	x := 1
	for i := 0; i < 255; i++ {
		gfExp[i] = byte(x)
		gfLog[x] = byte(i)
		x <<= 1
		if x&0x100 != 0 {
			x ^= 0x11D
		}
	}
	for i := 255; i < 512; i++ {
		gfExp[i] = gfExp[i-255]
	}
}

// gfMul multiplies two field elements using the log tables.
func gfMul(a, b byte) byte {
	if a == 0 || b == 0 {
		return 0
	}
	return gfExp[int(gfLog[a])+int(gfLog[b])]
}
