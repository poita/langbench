package mmio

import (
	"os"
	"strconv"

	"linalg"
)

const banner = "%%MatrixMarket matrix array real general\n"

// Format renders m in "array real general" form: the banner, the size line
// and rows*cols values in column-major order, one per line, each formatted
// like C's printf("%.10e"). Negative zero is written as positive zero.
func Format(m *linalg.Matrix) []byte {
	buf := make([]byte, 0, len(banner)+32+m.Rows*m.Cols*18)
	buf = append(buf, banner...)
	buf = strconv.AppendInt(buf, int64(m.Rows), 10)
	buf = append(buf, ' ')
	buf = strconv.AppendInt(buf, int64(m.Cols), 10)
	buf = append(buf, '\n')
	for j := 0; j < m.Cols; j++ {
		for i := 0; i < m.Rows; i++ {
			v := m.Data[i*m.Cols+j]
			if v == 0 {
				v = 0 // normalise -0.0
			}
			buf = strconv.AppendFloat(buf, v, 'e', 10, 64)
			buf = append(buf, '\n')
		}
	}
	return buf
}

// WriteFile writes m to path with a single write.
func WriteFile(path string, m *linalg.Matrix) error {
	return os.WriteFile(path, Format(m), 0o644)
}
