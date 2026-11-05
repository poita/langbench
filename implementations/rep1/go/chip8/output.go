package chip8

// hexDigits are the lowercase hexadecimal digits.
const hexDigits = "0123456789abcdef"

func appendHex(dst []byte, v uint32, width int) []byte {
	for i := width - 1; i >= 0; i-- {
		dst = append(dst, hexDigits[v>>(4*uint(i))&0xF])
	}
	return dst
}

func appendDec(dst []byte, v int) []byte {
	if v >= 10 {
		dst = appendDec(dst, v/10)
	}
	return append(dst, byte('0'+v%10))
}

// AppendReport appends the 34-line textual report to dst: the 32 display
// rows, the "PC=... I=... SP=... DT=... ST=..." line and the "V=..." line.
func (m *Machine) AppendReport(dst []byte) []byte {
	dst = m.Display.AppendRows(dst)
	dst = append(dst, "PC="...)
	dst = appendHex(dst, uint32(m.PC), 4)
	dst = append(dst, " I="...)
	dst = appendHex(dst, uint32(m.I), 4)
	dst = append(dst, " SP="...)
	dst = appendDec(dst, m.SP)
	dst = append(dst, " DT="...)
	dst = appendHex(dst, uint32(m.DT), 2)
	dst = append(dst, " ST="...)
	dst = appendHex(dst, uint32(m.ST), 2)
	dst = append(dst, "\nV="...)
	for i, r := range m.V {
		if i > 0 {
			dst = append(dst, ' ')
		}
		dst = appendHex(dst, uint32(r), 2)
	}
	return append(dst, '\n')
}

// Report returns the 34-line textual report of the machine's display and CPU
// state. See AppendReport.
func (m *Machine) Report() []byte {
	return m.AppendReport(make([]byte, 0, Height*(Width+1)+128))
}
