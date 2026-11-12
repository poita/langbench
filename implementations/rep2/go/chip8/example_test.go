package chip8_test

import (
	"fmt"
	"strings"

	"github.com/peter/chip8"
)

// Run a small program that adds two registers and then loops forever.
func Example() {
	prog, err := chip8.ParseInput("60ff7001610180141208\n6\n")
	if err != nil {
		panic(err)
	}
	m, err := prog.Execute()
	if err != nil {
		panic(err)
	}
	report := m.Report()
	fmt.Print(report[strings.Index(report, "PC="):])
	// Output:
	// PC=0208 I=0000 SP=0 DT=00 ST=00
	// V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
}
