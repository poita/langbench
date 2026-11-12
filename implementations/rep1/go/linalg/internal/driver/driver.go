// Package driver implements the linalg command-line contract: it executes the
// script in commands.txt and writes one set of result files per command.
package driver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"example.com/linalg"
	"example.com/linalg/mmio"
)

// maxCommands is the longest script that is executed.
const maxCommands = 200

// Command is one parsed script line.
type Command struct {
	Op   string
	Args []string
}

// arity gives the number of matrix arguments of every operation.
var arity = map[string]int{
	"add": 2, "mul": 2, "transpose": 1, "lu": 1, "det": 1, "inv": 1,
	"solve": 2, "qr": 1, "chol": 1, "eig": 1, "svd": 1, "lstsq": 2,
	"norm1": 1, "norminf": 1, "normfro": 1, "cond": 1,
}

// ParseScript splits the text of commands.txt into commands, skipping blank
// lines and comments.
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

// Result is one named output matrix; the file is NNN_<Suffix>.mtx.
type Result struct {
	Suffix string
	Matrix *linalg.Matrix
}

func scalar(v float64) *linalg.Matrix {
	m := linalg.New(1, 1)
	m.Data[0] = v
	return m
}

func column(v []float64) *linalg.Matrix {
	m := linalg.New(len(v), 1)
	copy(m.Data, v)
	return m
}

// Execute runs one operation on its already loaded arguments.
func Execute(op string, a []*linalg.Matrix) ([]Result, error) {
	one := func(m *linalg.Matrix, err error) ([]Result, error) {
		if err != nil {
			return nil, err
		}
		return []Result{{op, m}}, nil
	}
	switch op {
	case "add":
		return one(linalg.Add(a[0], a[1]))
	case "mul":
		return one(linalg.Mul(a[0], a[1]))
	case "transpose":
		return one(linalg.Transpose(a[0]), nil)
	case "lu":
		f, err := linalg.LU(a[0])
		if err != nil {
			return nil, err
		}
		return []Result{{"lu_P", f.P()}, {"lu_L", f.L()}, {"lu_U", f.U()}}, nil
	case "det":
		d, err := linalg.Det(a[0])
		if err != nil {
			return nil, err
		}
		return []Result{{op, scalar(d)}}, nil
	case "inv":
		return one(linalg.Inverse(a[0]))
	case "solve":
		return one(linalg.Solve(a[0], a[1]))
	case "qr":
		f, err := linalg.QR(a[0])
		if err != nil {
			return nil, err
		}
		return []Result{{"qr_Q", f.Q}, {"qr_R", f.R}}, nil
	case "chol":
		l, err := linalg.Cholesky(a[0])
		if err != nil {
			return nil, err
		}
		return []Result{{"chol_L", l}}, nil
	case "eig":
		w, v, err := linalg.SymEigen(a[0])
		if err != nil {
			return nil, err
		}
		return []Result{{"eig_w", column(w)}, {"eig_V", v}}, nil
	case "svd":
		f := linalg.SVD(a[0])
		return []Result{{"svd_U", f.U}, {"svd_S", column(f.S)}, {"svd_V", f.V}}, nil
	case "lstsq":
		return one(linalg.LeastSquares(a[0], a[1]))
	case "norm1":
		return []Result{{op, scalar(linalg.Norm1(a[0]))}}, nil
	case "norminf":
		return []Result{{op, scalar(linalg.NormInf(a[0]))}}, nil
	case "normfro":
		return []Result{{op, scalar(linalg.NormFro(a[0]))}}, nil
	case "cond":
		c, err := linalg.Cond(a[0])
		if err != nil {
			return nil, err
		}
		return []Result{{op, scalar(c)}}, nil
	}
	return nil, fmt.Errorf("unknown operation %q", op)
}

// Run executes the script in inDir/commands.txt, writing results to outDir.
// Matrix files are parsed at most once. A command that fails with one of the
// library's error codes writes NNN_error.txt; the run carries on.
func Run(inDir, outDir string) error {
	text, err := os.ReadFile(filepath.Join(inDir, "commands.txt"))
	if err != nil {
		return err
	}
	cmds := ParseScript(string(text))
	if len(cmds) > maxCommands {
		cmds = cmds[:maxCommands]
	}
	cache := map[string]*linalg.Matrix{}
	load := func(name string) (*linalg.Matrix, error) {
		if m, ok := cache[name]; ok {
			return m, nil
		}
		m, err := mmio.ReadFile(filepath.Join(inDir, name))
		if err != nil {
			return nil, err
		}
		cache[name] = m
		return m, nil
	}

	for idx, c := range cmds {
		num := idx + 1
		writeErr := func(code string) error {
			name := fmt.Sprintf("%03d_error.txt", num)
			return os.WriteFile(filepath.Join(outDir, name), []byte(code+"\n"), 0o644)
		}
		n, known := arity[c.Op]
		if !known || len(c.Args) != n {
			fmt.Fprintf(os.Stderr, "command %d: malformed %q\n", num, c.Op)
			if err := writeErr("invalid_command"); err != nil {
				return err
			}
			continue
		}
		args := make([]*linalg.Matrix, n)
		var loadErr error
		for i, name := range c.Args {
			if args[i], loadErr = load(name); loadErr != nil {
				break
			}
		}
		if loadErr != nil {
			fmt.Fprintf(os.Stderr, "command %d: %v\n", num, loadErr)
			if err := writeErr("invalid_input"); err != nil {
				return err
			}
			continue
		}
		results, err := Execute(c.Op, args)
		if err != nil {
			code, ok := linalg.ErrorCode(err)
			if !ok {
				return fmt.Errorf("command %d: %w", num, err)
			}
			if err := writeErr(code); err != nil {
				return err
			}
			continue
		}
		for _, r := range results {
			name := fmt.Sprintf("%03d_%s.mtx", num, r.Suffix)
			if err := mmio.WriteFile(filepath.Join(outDir, name), r.Matrix); err != nil {
				return err
			}
		}
	}
	return nil
}
