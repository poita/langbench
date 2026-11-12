// Command chip8 reads a ROM, a cycle budget and an optional key schedule from
// standard input, runs the CHIP-8 machine for that many cycles and prints the
// display and CPU state to standard output.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"github.com/peter/chip8"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "chip8:", err)
		os.Exit(1)
	}
}

func run(in io.Reader, out io.Writer) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	prog, err := chip8.ParseInput(string(data))
	if err != nil {
		return err
	}
	m, err := prog.Execute()
	if err != nil {
		return err
	}
	w := bufio.NewWriter(out)
	if _, err := w.WriteString(m.Report()); err != nil {
		return err
	}
	return w.Flush()
}
