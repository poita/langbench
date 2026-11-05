package sat

import (
	"bufio"
	"io"
	"strconv"
)

// WriteResult writes the answer in the format
//
//	SAT
//	l1 l2 ... lV 0
//
// for a satisfiable formula (li is i if variable i is true, -i otherwise) or
//
//	UNSAT
//
// for an unsatisfiable one. The whole output is built in one buffer.
func WriteResult(w io.Writer, st Status, model []bool) error {
	bw := bufio.NewWriterSize(w, 1<<16)
	if st != Satisfiable {
		bw.WriteString("UNSAT\n")
		return bw.Flush()
	}
	bw.WriteString("SAT\n")
	var buf [24]byte
	for i, v := range model {
		n := i + 1
		b := buf[:0]
		if !v {
			b = append(b, '-')
		}
		b = strconv.AppendInt(b, int64(n), 10)
		b = append(b, ' ')
		bw.Write(b)
	}
	bw.WriteString("0\n")
	return bw.Flush()
}
