// Command datalog reads a Datalog program on standard input, computes its
// stratified model and prints the answers to the program's queries.
//
// For each query it prints the matching tuples, one per line in ascending
// order, then a line "-- N". If the program is unsafe or not stratifiable it
// prints "error" instead. The exit status is 0 in both cases; a syntax error
// is reported on standard error with exit status 1.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"

	"example.com/datalog"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr))
}

func run(stdin io.Reader, stdout, stderr io.Writer) int {
	src, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintln(stderr, "datalog:", err)
		return 1
	}
	results, err := datalog.Run(string(src))
	if err != nil {
		var syn *datalog.SyntaxError
		if errors.As(err, &syn) {
			fmt.Fprintln(stderr, "datalog:", err)
			return 1
		}
		fmt.Fprintln(stderr, "datalog:", err)
		fmt.Fprintln(stdout, "error")
		return 0
	}
	w := bufio.NewWriter(stdout)
	if err := datalog.WriteResults(w, results); err == nil {
		err = w.Flush()
	}
	if err != nil {
		fmt.Fprintln(stderr, "datalog:", err)
		return 1
	}
	return 0
}
