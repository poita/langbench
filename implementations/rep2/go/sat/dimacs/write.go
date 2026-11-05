package dimacs

import (
	"io"
	"strconv"
)

// AppendResult appends the textual result to dst and returns the extended
// slice. For an unsatisfiable formula (sat == false) that is "UNSAT\n". For a
// satisfiable one it is "SAT\n" followed by one literal per variable
// (model[i] is the value of variable i+1) and a closing 0.
func AppendResult(dst []byte, sat bool, model []bool) []byte {
	if !sat {
		return append(dst, "UNSAT\n"...)
	}
	dst = append(dst, "SAT\n"...)
	for i, val := range model {
		x := i + 1
		if !val {
			x = -x
		}
		dst = strconv.AppendInt(dst, int64(x), 10)
		dst = append(dst, ' ')
	}
	return append(dst, "0\n"...)
}

// WriteResult writes the result in the format of AppendResult to w with a
// single Write call.
func WriteResult(w io.Writer, sat bool, model []bool) error {
	_, err := w.Write(AppendResult(make([]byte, 0, 16+8*len(model)), sat, model))
	return err
}
