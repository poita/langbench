package chip8

import "strconv"

const hexDigits = "0123456789abcdef"

func appendHex(b []byte, v uint16, width int) []byte {
	for i := width - 1; i >= 0; i-- {
		b = append(b, hexDigits[(v>>(4*uint(i)))&0xF])
	}
	return b
}

// Render formats the machine as the 34-line text report: 32 display rows of
// '#'/'.' followed by the PC/I/SP/DT/ST line and the V register line.
func (m *Machine) Render() []byte {
	buf := make([]byte, 0, Height*(Width+1)+128)
	for y := 0; y < Height; y++ {
		row := m.Display[y]
		for x := 0; x < Width; x++ {
			if row>>(63-uint(x))&1 != 0 {
				buf = append(buf, '#')
			} else {
				buf = append(buf, '.')
			}
		}
		buf = append(buf, '\n')
	}
	buf = append(buf, "PC="...)
	buf = appendHex(buf, m.PC, 4)
	buf = append(buf, " I="...)
	buf = appendHex(buf, m.I, 4)
	buf = append(buf, " SP="...)
	buf = strconv.AppendInt(buf, int64(m.SP), 10)
	buf = append(buf, " DT="...)
	buf = appendHex(buf, uint16(m.DT), 2)
	buf = append(buf, " ST="...)
	buf = appendHex(buf, uint16(m.ST), 2)
	buf = append(buf, "\nV="...)
	for i, v := range m.V {
		if i > 0 {
			buf = append(buf, ' ')
		}
		buf = appendHex(buf, uint16(v), 2)
	}
	return append(buf, '\n')
}
