// Package mmio reads and writes the Matrix Market formats used by linalg.
//
// Reading accepts the coordinate and array formats with the real, integer
// and pattern fields and the general, symmetric and skew-symmetric
// symmetries, and always produces a dense matrix. Writing always produces
// "array real general" with every value formatted like C's "%.10e".
package mmio

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"example.com/linalg"
)

// Read parses a Matrix Market document into a dense matrix.
func Read(r io.Reader) (*linalg.Matrix, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	return Parse(string(data))
}

// ReadFile parses the Matrix Market file at path.
func ReadFile(path string) (*linalg.Matrix, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(string(data))
}

type lineScanner struct {
	rest string
}

// next returns the next line that is not blank, with surrounding whitespace
// removed.
func (s *lineScanner) next() (string, bool) {
	for s.rest != "" {
		var line string
		if i := strings.IndexByte(s.rest, '\n'); i >= 0 {
			line, s.rest = s.rest[:i], s.rest[i+1:]
		} else {
			line, s.rest = s.rest, ""
		}
		line = strings.TrimSpace(line)
		if line != "" {
			return line, true
		}
	}
	return "", false
}

// Parse parses the text of a Matrix Market file into a dense matrix.
func Parse(text string) (*linalg.Matrix, error) {
	text = strings.TrimPrefix(text, "\ufeff")
	i := strings.IndexByte(text, '\n')
	banner := text
	rest := ""
	if i >= 0 {
		banner, rest = text[:i], text[i+1:]
	}
	f := strings.Fields(strings.ToLower(banner))
	if len(f) != 5 || f[0] != "%%matrixmarket" || f[1] != "matrix" {
		return nil, fmt.Errorf("mmio: bad banner %q", strings.TrimSpace(banner))
	}
	format, field, sym := f[2], f[3], f[4]
	if format != "coordinate" && format != "array" {
		return nil, fmt.Errorf("mmio: unsupported format %q", format)
	}
	if field != "real" && field != "integer" && field != "pattern" {
		return nil, fmt.Errorf("mmio: unsupported field %q", field)
	}
	if field == "pattern" && format != "coordinate" {
		return nil, fmt.Errorf("mmio: pattern requires coordinate format")
	}
	if sym != "general" && sym != "symmetric" && sym != "skew-symmetric" {
		return nil, fmt.Errorf("mmio: unsupported symmetry %q", sym)
	}

	sc := &lineScanner{rest: rest}
	var size string
	for {
		line, ok := sc.next()
		if !ok {
			return nil, fmt.Errorf("mmio: missing size line")
		}
		if line[0] != '%' {
			size = line
			break
		}
	}
	dims, err := parseInts(size)
	if err != nil {
		return nil, err
	}

	if format == "coordinate" {
		if len(dims) != 3 {
			return nil, fmt.Errorf("mmio: bad coordinate size line %q", size)
		}
		return readCoordinate(sc, dims[0], dims[1], dims[2], field == "pattern", sym)
	}
	if len(dims) != 2 {
		return nil, fmt.Errorf("mmio: bad array size line %q", size)
	}
	return readArray(sc, dims[0], dims[1], sym)
}

func parseInts(line string) ([]int, error) {
	fs := strings.Fields(line)
	out := make([]int, len(fs))
	for i, s := range fs {
		v, err := strconv.Atoi(s)
		if err != nil || v < 0 {
			return nil, fmt.Errorf("mmio: bad integer %q", s)
		}
		out[i] = v
	}
	return out, nil
}

func readCoordinate(sc *lineScanner, rows, cols, nnz int, pattern bool, sym string) (*linalg.Matrix, error) {
	m := linalg.New(rows, cols)
	want := 3
	if pattern {
		want = 2
	}
	for n := 0; n < nnz; n++ {
		line, ok := sc.next()
		if !ok {
			return nil, fmt.Errorf("mmio: expected %d entries, got %d", nnz, n)
		}
		fs := strings.Fields(line)
		if len(fs) < want {
			return nil, fmt.Errorf("mmio: bad entry %q", line)
		}
		i, err1 := strconv.Atoi(fs[0])
		j, err2 := strconv.Atoi(fs[1])
		if err1 != nil || err2 != nil || i < 1 || i > rows || j < 1 || j > cols {
			return nil, fmt.Errorf("mmio: bad index in %q", line)
		}
		v := 1.0
		if !pattern {
			if v, err1 = strconv.ParseFloat(fs[2], 64); err1 != nil {
				return nil, fmt.Errorf("mmio: bad value in %q", line)
			}
		}
		i--
		j--
		m.Set(i, j, v)
		if i != j {
			switch sym {
			case "symmetric":
				m.Set(j, i, v)
			case "skew-symmetric":
				m.Set(j, i, -v)
			}
		}
	}
	return m, nil
}

func readArray(sc *lineScanner, rows, cols int, sym string) (*linalg.Matrix, error) {
	m := linalg.New(rows, cols)
	next := func() (float64, error) {
		line, ok := sc.next()
		if !ok {
			return 0, fmt.Errorf("mmio: unexpected end of data")
		}
		fs := strings.Fields(line)
		v, err := strconv.ParseFloat(fs[0], 64)
		if err != nil {
			return 0, fmt.Errorf("mmio: bad value %q", line)
		}
		return v, nil
	}
	for j := 0; j < cols; j++ {
		start := 0
		switch sym {
		case "symmetric":
			start = j
		case "skew-symmetric":
			start = j + 1
		}
		for i := start; i < rows; i++ {
			v, err := next()
			if err != nil {
				return nil, err
			}
			m.Set(i, j, v)
			if i != j {
				switch sym {
				case "symmetric":
					m.Set(j, i, v)
				case "skew-symmetric":
					m.Set(j, i, -v)
				}
			}
		}
	}
	return m, nil
}

// FormatValue formats v like C's printf("%.10e"), writing negative zero as
// positive zero.
func FormatValue(v float64) string {
	return string(appendValue(nil, v))
}

func appendValue(b []byte, v float64) []byte {
	if v == 0 {
		v = 0 // normalise -0.0
	}
	return strconv.AppendFloat(b, v, 'e', 10, 64)
}

// Write writes m as "array real general" to w.
func Write(w io.Writer, m *linalg.Matrix) error {
	bw := bufio.NewWriter(w)
	fmt.Fprintf(bw, "%%%%MatrixMarket matrix array real general\n%d %d\n", m.Rows, m.Cols)
	buf := make([]byte, 0, 32)
	for j := 0; j < m.Cols; j++ {
		for i := 0; i < m.Rows; i++ {
			buf = appendValue(buf[:0], m.Data[i*m.Cols+j])
			buf = append(buf, '\n')
			bw.Write(buf)
		}
	}
	return bw.Flush()
}

// WriteFile writes m to the file at path in "array real general" form.
func WriteFile(path string, m *linalg.Matrix) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := Write(f, m); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
