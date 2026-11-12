package chip8

import (
	"fmt"
	"strings"
)

// Report formats the machine state as the 34-line textual report: the 32
// display rows, the PC/I/SP/DT/ST line and the register line.
func (m *Machine) Report() string {
	var sb strings.Builder
	sb.WriteString(m.Display.String())
	fmt.Fprintf(&sb, "PC=%04x I=%04x SP=%d DT=%02x ST=%02x\n", m.PC, m.I, m.SP, m.DT, m.ST)
	sb.WriteString("V=")
	for i, v := range m.V {
		if i > 0 {
			sb.WriteByte(' ')
		}
		fmt.Fprintf(&sb, "%02x", v)
	}
	sb.WriteByte('\n')
	return sb.String()
}
