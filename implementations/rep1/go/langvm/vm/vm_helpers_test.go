package vm

import (
	"math"

	"langvm/builtins"
)

var builtinIDs = builtins.IDs

func nanValue() float64 { return math.NaN() }
