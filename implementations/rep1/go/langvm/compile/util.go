package compile

import "math"

func floatBits(x float64) uint64 { return math.Float64bits(x) }
