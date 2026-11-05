// Command chip8 reads a ROM, a cycle budget and an optional key schedule from
// standard input, runs the CHIP-8 machine and prints the final display and CPU
// state to standard output.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/example/chip8"
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
	prog, err := chip8.ParseInput(data)
	if err != nil {
		return err
	}
	m, err := prog.Run()
	if err != nil {
		return err
	}
	_, err = out.Write(m.Report())
	return err
}
