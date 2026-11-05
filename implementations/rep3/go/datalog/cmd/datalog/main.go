// Command datalog reads a Datalog program from standard input, computes its
// stratified model and prints the answer to every query. An unsafe or
// unstratifiable program prints "error".
package main

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/example/datalog"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr))
}

func run(in io.Reader, out, errw io.Writer) int {
	src, err := io.ReadAll(in)
	if err != nil {
		fmt.Fprintln(errw, err)
		return 1
	}
	prog, err := datalog.Parse(src)
	if err != nil {
		fmt.Fprintln(errw, err)
		return 1
	}
	model, err := prog.Solve()
	if err != nil {
		if errors.Is(err, datalog.ErrUnsafe) || errors.Is(err, datalog.ErrNotStratifiable) {
			fmt.Fprintln(errw, err)
			fmt.Fprintln(out, "error")
			return 0
		}
		fmt.Fprintln(errw, err)
		return 1
	}
	if err := datalog.WriteAnswers(out, model.Answers()); err != nil {
		fmt.Fprintln(errw, err)
		return 1
	}
	return 0
}
