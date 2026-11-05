// Package driver implements the linalg command-line contract: it reads a
// commands.txt script and the matrices it names from an input directory and
// writes one result file per operation into an output directory.
package driver

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"linalg"
	"linalg/mmio"
)

// result is one output matrix with its file-name suffix.
type result struct {
	suffix string
	m      *linalg.Matrix
}

type operation struct {
	args int
	run  func(a []*linalg.Matrix) ([]result, error)
}

func one(suffix string, m *linalg.Matrix, err error) ([]result, error) {
	if err != nil {
		return nil, err
	}
	return []result{{suffix, m}}, nil
}

func scalar(suffix string, v float64, err error) ([]result, error) {
	if err != nil {
		return nil, err
	}
	return []result{{suffix, linalg.Scalar(v)}}, nil
}

var operations = map[string]operation{
	"add": {2, func(a []*linalg.Matrix) ([]result, error) {
		m, err := linalg.Add(a[0], a[1])
		return one("add", m, err)
	}},
	"mul": {2, func(a []*linalg.Matrix) ([]result, error) {
		m, err := linalg.Mul(a[0], a[1])
		return one("mul", m, err)
	}},
	"transpose": {1, func(a []*linalg.Matrix) ([]result, error) {
		return one("transpose", linalg.Transpose(a[0]), nil)
	}},
	"lu": {1, func(a []*linalg.Matrix) ([]result, error) {
		f, err := linalg.NewLU(a[0])
		if err != nil {
			return nil, err
		}
		return []result{{"lu_P", f.P()}, {"lu_L", f.L()}, {"lu_U", f.U()}}, nil
	}},
	"det": {1, func(a []*linalg.Matrix) ([]result, error) {
		d, err := linalg.Det(a[0])
		return scalar("det", d, err)
	}},
	"inv": {1, func(a []*linalg.Matrix) ([]result, error) {
		m, err := linalg.Inverse(a[0])
		return one("inv", m, err)
	}},
	"solve": {2, func(a []*linalg.Matrix) ([]result, error) {
		m, err := linalg.Solve(a[0], a[1])
		return one("solve", m, err)
	}},
	"qr": {1, func(a []*linalg.Matrix) ([]result, error) {
		f, err := linalg.QR(a[0])
		if err != nil {
			return nil, err
		}
		return []result{{"qr_Q", f.Q}, {"qr_R", f.R}}, nil
	}},
	"chol": {1, func(a []*linalg.Matrix) ([]result, error) {
		m, err := linalg.Cholesky(a[0])
		return one("chol_L", m, err)
	}},
	"eig": {1, func(a []*linalg.Matrix) ([]result, error) {
		e, err := linalg.EigSym(a[0])
		if err != nil {
			return nil, err
		}
		return []result{{"eig_w", linalg.ColVector(e.Values)}, {"eig_V", e.Vectors}}, nil
	}},
	"svd": {1, func(a []*linalg.Matrix) ([]result, error) {
		f := linalg.SVD(a[0])
		return []result{{"svd_U", f.U}, {"svd_S", linalg.ColVector(f.S)}, {"svd_V", f.V}}, nil
	}},
	"lstsq": {2, func(a []*linalg.Matrix) ([]result, error) {
		m, err := linalg.LeastSquares(a[0], a[1])
		return one("lstsq", m, err)
	}},
	"norm1": {1, func(a []*linalg.Matrix) ([]result, error) {
		return scalar("norm1", linalg.Norm1(a[0]), nil)
	}},
	"norminf": {1, func(a []*linalg.Matrix) ([]result, error) {
		return scalar("norminf", linalg.NormInf(a[0]), nil)
	}},
	"normfro": {1, func(a []*linalg.Matrix) ([]result, error) {
		return scalar("normfro", linalg.NormFro(a[0]), nil)
	}},
	"cond": {1, func(a []*linalg.Matrix) ([]result, error) {
		c, err := linalg.Cond(a[0])
		return scalar("cond", c, err)
	}},
}

// Command is one parsed line of commands.txt.
type Command struct {
	Op   string
	Args []string
}

// ParseScript extracts the commands from the text of commands.txt. Lines are
// trimmed of spaces and tabs; empty lines and '#' comments are skipped.
func ParseScript(text string) []Command {
	var cmds []Command
	for _, line := range strings.Split(text, "\n") {
		line = strings.Trim(line, " \t\r")
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' })
		cmds = append(cmds, Command{Op: f[0], Args: f[1:]})
	}
	return cmds
}

// Run executes the script in inDir, writing results to outDir. Per-command
// failures are recorded as NNN_error.txt; only an unreadable commands.txt or
// an unwritable output directory is returned as an error.
func Run(inDir, outDir string) error {
	text, err := os.ReadFile(filepath.Join(inDir, "commands.txt"))
	if err != nil {
		return err
	}
	cache := map[string]*linalg.Matrix{}
	load := func(name string) (*linalg.Matrix, error) {
		if m, ok := cache[name]; ok {
			return m, nil
		}
		m, err := mmio.ReadFile(filepath.Join(inDir, filepath.Base(name)))
		if err != nil {
			return nil, err
		}
		cache[name] = m
		return m, nil
	}
	var firstErr error
	for i, cmd := range ParseScript(string(text)) {
		num := fmt.Sprintf("%03d", i+1)
		results, err := execute(cmd, load)
		if err != nil {
			code := err.Error()
			if !isLibraryError(err) {
				fmt.Fprintf(os.Stderr, "command %s (%s): %v\n", num, cmd.Op, err)
				code = "invalid_input"
			}
			if werr := os.WriteFile(filepath.Join(outDir, num+"_error.txt"), []byte(code+"\n"), 0o644); werr != nil && firstErr == nil {
				firstErr = werr
			}
			continue
		}
		for _, r := range results {
			if werr := mmio.WriteFile(filepath.Join(outDir, num+"_"+r.suffix+".mtx"), r.m); werr != nil && firstErr == nil {
				firstErr = werr
			}
		}
	}
	return firstErr
}

func isLibraryError(err error) bool {
	for _, e := range []error{linalg.ErrDimensionMismatch, linalg.ErrNotSquare,
		linalg.ErrNotSymmetric, linalg.ErrNotPositiveDefinite, linalg.ErrSingular} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}

func execute(cmd Command, load func(string) (*linalg.Matrix, error)) ([]result, error) {
	op, ok := operations[cmd.Op]
	if !ok {
		return nil, fmt.Errorf("unknown operation %q", cmd.Op)
	}
	if len(cmd.Args) != op.args {
		return nil, fmt.Errorf("%s takes %d arguments, got %d", cmd.Op, op.args, len(cmd.Args))
	}
	args := make([]*linalg.Matrix, len(cmd.Args))
	for i, name := range cmd.Args {
		m, err := load(name)
		if err != nil {
			return nil, err
		}
		args[i] = m
	}
	return op.run(args)
}
