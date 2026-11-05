package qr

// ECL is an error correction level.
type ECL int

// Error correction levels, in increasing order of redundancy.
const (
	L ECL = iota // ~7% of codewords can be restored
	M            // ~15%
	Q            // ~25%
	H            // ~30%
)

// String returns "L", "M", "Q" or "H".
func (e ECL) String() string {
	if e < L || e > H {
		return "?"
	}
	return "LMQH"[e : e+1]
}

// ParseECL converts "L", "M", "Q" or "H" to an ECL.
func ParseECL(s string) (ECL, bool) {
	if len(s) == 1 {
		for e := L; e <= H; e++ {
			if s[0] == "LMQH"[e] {
				return e, true
			}
		}
	}
	return 0, false
}

// formatBits holds the 2-bit ECL indicator used in format information.
var formatBits = [4]int{1, 0, 3, 2}

// Version limits.
const (
	MinVersion = 1
	MaxVersion = 40
)

// eccPerBlock[ecl][v-1] is the number of ECC codewords per block.
var eccPerBlock = [4][40]int{
	{7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
	{10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28},
	{13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
	{17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30},
}

// numBlocks[ecl][v-1] is the number of Reed-Solomon blocks.
var numBlocks = [4][40]int{
	{1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25},
	{1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49},
	{1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68},
	{1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81},
}

// alignPos[v-1] lists the alignment pattern centre coordinates of version v.
var alignPos = [40][]int{
	nil, {6, 18}, {6, 22}, {6, 26}, {6, 30}, {6, 34},
	{6, 22, 38}, {6, 24, 42}, {6, 26, 46}, {6, 28, 50}, {6, 30, 54}, {6, 32, 58}, {6, 34, 62},
	{6, 26, 46, 66}, {6, 26, 48, 70}, {6, 26, 50, 74}, {6, 30, 54, 78}, {6, 30, 56, 82}, {6, 30, 58, 86}, {6, 34, 62, 90},
	{6, 28, 50, 72, 94}, {6, 26, 50, 74, 98}, {6, 30, 54, 78, 102}, {6, 28, 54, 80, 106}, {6, 32, 58, 84, 110},
	{6, 30, 58, 86, 114}, {6, 34, 62, 90, 118}, {6, 26, 50, 74, 98, 122}, {6, 30, 54, 78, 102, 126},
	{6, 26, 52, 78, 104, 130}, {6, 30, 56, 82, 108, 134}, {6, 34, 60, 86, 112, 138}, {6, 30, 58, 86, 114, 142},
	{6, 34, 62, 90, 118, 146}, {6, 30, 54, 78, 102, 126, 150}, {6, 24, 50, 76, 102, 128, 154},
	{6, 28, 54, 80, 106, 132, 158}, {6, 32, 58, 84, 110, 136, 162}, {6, 26, 54, 82, 110, 138, 166},
	{6, 30, 58, 86, 114, 142, 170},
}

// Size returns the side length in modules of a symbol of version v.
func Size(v int) int { return 4*v + 17 }

// rawModules returns the number of modules available for codewords
// (including remainder bits) in version v.
func rawModules(v int) int {
	raw := (16*v+128)*v + 64
	if v >= 2 {
		a := v/7 + 2
		raw -= (25*a-10)*a - 55
		if v >= 7 {
			raw -= 36
		}
	}
	return raw
}

// totalCodewords returns the number of data plus ECC codewords of version v.
func totalCodewords(v int) int { return rawModules(v) / 8 }

// dataCodewords returns the number of data codewords of version v at level ecl.
func dataCodewords(v int, ecl ECL) int {
	return totalCodewords(v) - eccPerBlock[ecl][v-1]*numBlocks[ecl][v-1]
}
