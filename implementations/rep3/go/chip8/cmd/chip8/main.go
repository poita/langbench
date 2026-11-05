// Command chip8 reads a ROM, a cycle budget and an optional key schedule from
// stdin, runs the CHIP-8 interpreter and prints the display and CPU state.
package main

import (
	"bufio"
	"fmt"
	"os"

	"github.com/example/chip8"
)

func main() {
	in, err := chip8.ParseInput(bufio.NewReader(os.Stdin))
	if err != nil {
		fmt.Fprintln(os.Stderr, "chip8:", err)
		os.Exit(1)
	}
	m := chip8.New()
	m.LoadROM(in.ROM)
	m.Run(in.Cycles, in.Events)
	if _, err := os.Stdout.Write(m.Render()); err != nil {
		fmt.Fprintln(os.Stderr, "chip8:", err)
		os.Exit(1)
	}
}
