package toml

import (
	"math"
	"strconv"
)

func nan() float64    { return math.NaN() }
func posInf() float64 { return math.Inf(1) }
func negInf() float64 { return math.Inf(-1) }

// formatFloat renders v in the canonical float text: "nan", "inf", "-inf", or
// exactly 17 significant digits in scientific notation (printf "%.16e").
func formatFloat(v float64) string {
	switch {
	case v != v:
		return "nan"
	case math.IsInf(v, 1):
		return "inf"
	case math.IsInf(v, -1):
		return "-inf"
	}
	// 'e' with precision 16 yields d.dddddddddddddddde±XX with at least two
	// exponent digits, exactly like C's %.16e.
	return strconv.FormatFloat(v, 'e', 16, 64)
}
