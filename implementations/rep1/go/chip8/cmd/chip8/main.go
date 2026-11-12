// Command chip8 reads a ROM, a cycle budget and an optional key schedule from
// stdin, runs the CHIP-8 machine for that many cycles and prints the final
// display and CPU state to stdout.
package main

import (
	"bufio"
	"fmt"
	"os"

	"github.com/example/chip8"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "chip8:", err)
		os.Exit(1)
	}
}

func run() error {
	prog, err := chip8.ParseProgram(bufio.NewReader(os.Stdin))
	if err != nil {
		return err
	}
	m, err := prog.Execute()
	if err != nil {
		return err
	}
	_, err = os.Stdout.WriteString(m.Report())
	return err
}
