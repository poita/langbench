package dimacs

import (
	"io"
	"strconv"
)

// WriteResult writes a solver verdict in the sat command's output format.
//
// If satisfiable is false it writes "UNSAT\n". Otherwise it writes "SAT\n"
// followed by one line holding a literal for every variable (model[i] is the
// value of variable i+1) and a terminating 0. The output is assembled in one
// buffer and written with a single call to w.
func WriteResult(w io.Writer, satisfiable bool, model []bool) error {
	if !satisfiable {
		_, err := io.WriteString(w, "UNSAT\n")
		return err
	}
	buf := make([]byte, 0, 4+len(model)*8+3)
	buf = append(buf, "SAT\n"...)
	for i, v := range model {
		n := i + 1
		if !v {
			n = -n
		}
		buf = strconv.AppendInt(buf, int64(n), 10)
		buf = append(buf, ' ')
	}
	buf = append(buf, "0\n"...)
	_, err := w.Write(buf)
	return err
}
