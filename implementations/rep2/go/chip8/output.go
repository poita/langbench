package chip8

import "strconv"

const hexDigits = "0123456789abcdef"

// Format renders the machine as the 34 output lines: 32 display rows, the
// "PC=... I=... SP=... DT=.. ST=.." line and the "V=..." register line.
func (m *Machine) Format() []byte {
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
	buf = appendHex(buf, uint32(m.PC), 4)
	buf = append(buf, " I="...)
	buf = appendHex(buf, uint32(m.I), 4)
	buf = append(buf, " SP="...)
	buf = strconv.AppendInt(buf, int64(m.SP), 10)
	buf = append(buf, " DT="...)
	buf = appendHex(buf, uint32(m.DT), 2)
	buf = append(buf, " ST="...)
	buf = appendHex(buf, uint32(m.ST), 2)
	buf = append(buf, "\nV="...)
	for i, v := range m.V {
		if i > 0 {
			buf = append(buf, ' ')
		}
		buf = appendHex(buf, uint32(v), 2)
	}
	return append(buf, '\n')
}

func appendHex(buf []byte, v uint32, width int) []byte {
	for shift := 4 * (width - 1); shift >= 0; shift -= 4 {
		buf = append(buf, hexDigits[v>>uint(shift)&0xF])
	}
	return buf
}
