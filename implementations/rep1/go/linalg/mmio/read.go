// Package mmio reads and writes real matrices in the Matrix Market exchange
// format.
//
// Reading supports the coordinate and array formats with the real, integer
// and (for coordinate) pattern fields and the general, symmetric and
// skew-symmetric symmetries. The result is always a dense linalg.Matrix with
// symmetric storage expanded. Writing always produces "array real general".
package mmio

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"strconv"

	"linalg"
)

// ReadFile reads and parses a Matrix Market file.
func ReadFile(path string) (*linalg.Matrix, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Parse(data)
}

type scanner struct {
	data []byte
	pos  int
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' }

// token returns the next whitespace-separated token on the current line
// (nil at end of line) without consuming the newline.
func (s *scanner) token() []byte {
	d := s.data
	i := s.pos
	for i < len(d) && (d[i] == ' ' || d[i] == '\t' || d[i] == '\r') {
		i++
	}
	st := i
	for i < len(d) && !isSpace(d[i]) {
		i++
	}
	s.pos = i
	if i == st {
		return nil
	}
	return d[st:i]
}

// nextLine advances past the rest of the current line.
func (s *scanner) nextLine() {
	for s.pos < len(s.data) && s.data[s.pos] != '\n' {
		s.pos++
	}
	if s.pos < len(s.data) {
		s.pos++
	}
}

// nextToken returns the next token in the data section, crossing lines and
// skipping blank lines. It returns nil at end of input.
func (s *scanner) nextToken() []byte {
	for {
		if t := s.token(); t != nil {
			return t
		}
		if s.pos >= len(s.data) {
			return nil
		}
		s.nextLine()
	}
}

func parseInt(t []byte) (int, error) {
	if len(t) == 0 {
		return 0, errors.New("mmio: missing integer")
	}
	n := 0
	for _, c := range t {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("mmio: bad integer %q", t)
		}
		n = n*10 + int(c-'0')
		if n > 1<<40 {
			return 0, fmt.Errorf("mmio: integer too large %q", t)
		}
	}
	return n, nil
}

func (s *scanner) int() (int, error) { return parseInt(s.nextToken()) }

func (s *scanner) float() (float64, error) {
	t := s.nextToken()
	if t == nil {
		return 0, errors.New("mmio: unexpected end of data")
	}
	return strconv.ParseFloat(string(t), 64)
}

// Parse parses the contents of a Matrix Market file.
func Parse(data []byte) (*linalg.Matrix, error) {
	s := &scanner{data: data}
	var banner [5][]byte
	for i := range banner {
		banner[i] = s.token()
	}
	if !bytes.EqualFold(banner[0], []byte("%%MatrixMarket")) || !bytes.EqualFold(banner[1], []byte("matrix")) || banner[4] == nil {
		return nil, errors.New("mmio: bad banner")
	}
	format := string(bytes.ToLower(banner[2]))
	field := string(bytes.ToLower(banner[3]))
	symmetry := string(bytes.ToLower(banner[4]))
	if format != "coordinate" && format != "array" {
		return nil, fmt.Errorf("mmio: unsupported format %q", format)
	}
	if field != "real" && field != "integer" && field != "pattern" {
		return nil, fmt.Errorf("mmio: unsupported field %q", field)
	}
	if symmetry != "general" && symmetry != "symmetric" && symmetry != "skew-symmetric" {
		return nil, fmt.Errorf("mmio: unsupported symmetry %q", symmetry)
	}
	if field == "pattern" && format != "coordinate" {
		return nil, errors.New("mmio: pattern requires coordinate format")
	}
	s.nextLine()

	// Skip comments and blank lines up to the size line.
	for {
		if s.pos >= len(data) {
			return nil, errors.New("mmio: missing size line")
		}
		c := data[s.pos]
		if c == '%' {
			s.nextLine()
			continue
		}
		if isSpace(c) {
			if c == '\n' {
				s.pos++
				continue
			}
			// leading blanks: look at what follows on this line
			save := s.pos
			if s.token() == nil {
				s.nextLine()
				continue
			}
			s.pos = save
		}
		break
	}

	rows, err := s.int()
	if err != nil {
		return nil, err
	}
	cols, err := s.int()
	if err != nil {
		return nil, err
	}
	if rows <= 0 || cols <= 0 || rows*cols > 1<<28 {
		return nil, fmt.Errorf("mmio: bad dimensions %d x %d", rows, cols)
	}
	if symmetry != "general" && rows != cols {
		return nil, errors.New("mmio: symmetric matrix must be square")
	}
	m := linalg.New(rows, cols)
	d := m.Data
	sign := 1.0
	if symmetry == "skew-symmetric" {
		sign = -1
	}
	general := symmetry == "general"

	if format == "coordinate" {
		nnz, err := s.int()
		if err != nil {
			return nil, err
		}
		for e := 0; e < nnz; e++ {
			i, err := s.int()
			if err != nil {
				return nil, err
			}
			j, err := s.int()
			if err != nil {
				return nil, err
			}
			v := 1.0
			if field != "pattern" {
				if v, err = s.float(); err != nil {
					return nil, err
				}
			}
			if i < 1 || i > rows || j < 1 || j > cols {
				return nil, fmt.Errorf("mmio: index (%d, %d) out of range", i, j)
			}
			i--
			j--
			d[i*cols+j] = v
			if !general && i != j {
				d[j*cols+i] = sign * v
			}
		}
		return m, nil
	}

	// array format, column-major.
	switch symmetry {
	case "general":
		for j := 0; j < cols; j++ {
			for i := 0; i < rows; i++ {
				v, err := s.float()
				if err != nil {
					return nil, err
				}
				d[i*cols+j] = v
			}
		}
	default:
		n := rows
		for j := 0; j < n; j++ {
			start := j
			if symmetry == "skew-symmetric" {
				start = j + 1
			}
			for i := start; i < n; i++ {
				v, err := s.float()
				if err != nil {
					return nil, err
				}
				d[i*n+j] = v
				if i != j {
					d[j*n+i] = sign * v
				}
			}
		}
	}
	return m, nil
}
