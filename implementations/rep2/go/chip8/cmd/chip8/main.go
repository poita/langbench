// Command chip8 reads a ROM, a cycle budget and an optional key schedule from
// stdin, runs the CHIP-8 interpreter for exactly that many cycles and prints
// the display and CPU state to stdout.
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
	m := chip8.New()
	if err := m.LoadROM(prog.ROM); err != nil {
		return err
	}
	m.Run(prog.Cycles, prog.Schedule)
	_, err = out.Write(m.Format())
	return err
}
