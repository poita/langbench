package vm

import (
	"math"
	"strconv"
)

// formatFixed implements showFloatAt (SPEC 14.3) for 0 <= d <= 17.
func formatFixed(x float64, d int) []rune {
	if x != x {
		return []rune("nan")
	}
	if math.IsInf(x, 1) {
		return []rune("inf")
	}
	if math.IsInf(x, -1) {
		return []rune("-inf")
	}
	var stack [48]byte
	b := strconv.AppendFloat(stack[:0], x, 'f', d, 64)
	out := make([]rune, len(b))
	for i, c := range b {
		out[i] = rune(c)
	}
	return out
}

// parseFloatRunes implements the parseFloat grammar (SPEC 15.3).
func parseFloatRunes(s []rune) (float64, bool) {
	i, n := 0, len(s)
	if i < n && (s[i] == '+' || s[i] == '-') {
		i++
	}
	isDig := func(c rune) bool { return c >= '0' && c <= '9' }
	intDigits := 0
	for i < n && isDig(s[i]) {
		i++
		intDigits++
	}
	fracDigits := 0
	if i < n && s[i] == '.' {
		i++
		for i < n && isDig(s[i]) {
			i++
			fracDigits++
		}
		if intDigits == 0 && fracDigits == 0 {
			return 0, false
		}
	} else if intDigits == 0 {
		return 0, false
	}
	if i < n && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < n && (s[i] == '+' || s[i] == '-') {
			i++
		}
		ed := 0
		for i < n && isDig(s[i]) {
			i++
			ed++
		}
		if ed == 0 {
			return 0, false
		}
	}
	if i != n {
		return 0, false
	}
	var stack [64]byte
	b := stack[:0]
	for _, c := range s {
		b = append(b, byte(c))
	}
	f, err := strconv.ParseFloat(string(b), 64)
	if err != nil {
		if ne, ok := err.(*strconv.NumError); !ok || ne.Err != strconv.ErrRange {
			return 0, false
		}
	}
	return f, true
}
