package chip8

// skip advances PC past one instruction.
func (m *Machine) skip() { m.PC = (m.PC + 2) & addrMask }

// execute decodes and executes a single opcode. PC has already been advanced
// past it.
func (m *Machine) execute(op uint16) {
	x := byte(op >> 8 & 0xF)
	y := byte(op >> 4 & 0xF)
	n := byte(op & 0xF)
	nn := byte(op)
	nnn := op & 0xFFF

	switch op >> 12 {
	case 0x0:
		switch op {
		case 0x00E0:
			m.Display.Clear()
		case 0x00EE:
			if m.SP > 0 {
				m.SP--
				m.PC = m.Stack[m.SP] & addrMask
			}
		}
	case 0x1:
		m.PC = nnn
	case 0x2:
		// Pushing onto a full stack is unspecified; it is ignored here.
		if m.SP < StackDepth {
			m.Stack[m.SP] = m.PC
			m.SP++
		}
		m.PC = nnn
	case 0x3:
		if m.V[x] == nn {
			m.skip()
		}
	case 0x4:
		if m.V[x] != nn {
			m.skip()
		}
	case 0x5:
		if n == 0 && m.V[x] == m.V[y] {
			m.skip()
		}
	case 0x6:
		m.V[x] = nn
	case 0x7:
		m.V[x] += nn
	case 0x8:
		m.execALU(x, y, n)
	case 0x9:
		if n == 0 && m.V[x] != m.V[y] {
			m.skip()
		}
	case 0xA:
		m.I = nnn
	case 0xB:
		m.PC = (nnn + uint16(m.V[0])) & addrMask
	case 0xC:
		m.V[x] = m.RNG.Byte() & nn
	case 0xD:
		m.execDraw(x, y, n)
	case 0xE:
		switch nn {
		case 0x9E:
			if m.KeyDown(m.V[x]) {
				m.skip()
			}
		case 0xA1:
			if !m.KeyDown(m.V[x]) {
				m.skip()
			}
		}
	case 0xF:
		m.execMisc(x, nn)
	}
}

// execALU executes the 8XYN arithmetic and logic instructions. The result
// is written to VX before the flag is written to VF.
func (m *Machine) execALU(x, y, n byte) {
	vx, vy := m.V[x], m.V[y]
	switch n {
	case 0x0:
		m.V[x] = vy
	case 0x1:
		m.V[x] = vx | vy
	case 0x2:
		m.V[x] = vx & vy
	case 0x3:
		m.V[x] = vx ^ vy
	case 0x4:
		sum := uint16(vx) + uint16(vy)
		m.V[x] = byte(sum)
		m.V[0xF] = b2u(sum > 0xFF)
	case 0x5:
		m.V[x] = vx - vy
		m.V[0xF] = b2u(vx >= vy)
	case 0x6:
		m.V[x] = vx >> 1
		m.V[0xF] = vx & 1
	case 0x7:
		m.V[x] = vy - vx
		m.V[0xF] = b2u(vy >= vx)
	case 0xE:
		m.V[x] = vx << 1
		m.V[0xF] = vx >> 7
	}
}

// execDraw executes DXYN.
func (m *Machine) execDraw(x, y, n byte) {
	var rows [15]byte
	for r := 0; r < int(n); r++ {
		rows[r] = m.Mem[(int(m.I)+r)&addrMask]
	}
	hit := m.Display.DrawSprite(int(m.V[x]), int(m.V[y]), rows[:n])
	m.V[0xF] = b2u(hit)
}

// execMisc executes the FXNN instructions.
func (m *Machine) execMisc(x, nn byte) {
	switch nn {
	case 0x07:
		m.V[x] = m.DT
	case 0x0A:
		if m.Keys == 0 {
			m.PC = (m.PC - 2) & addrMask
			return
		}
		for k := byte(0); k < 16; k++ {
			if m.KeyDown(k) {
				m.V[x] = k
				break
			}
		}
	case 0x15:
		m.DT = m.V[x]
	case 0x18:
		m.ST = m.V[x]
	case 0x1E:
		m.I += uint16(m.V[x])
	case 0x29:
		m.I = FontAddr + uint16(m.V[x]&0xF)*GlyphSize
	case 0x33:
		v := m.V[x]
		m.Mem[int(m.I)&addrMask] = v / 100
		m.Mem[(int(m.I)+1)&addrMask] = v / 10 % 10
		m.Mem[(int(m.I)+2)&addrMask] = v % 10
	case 0x55:
		for k := 0; k <= int(x); k++ {
			m.Mem[(int(m.I)+k)&addrMask] = m.V[k]
		}
	case 0x65:
		for k := 0; k <= int(x); k++ {
			m.V[k] = m.Mem[(int(m.I)+k)&addrMask]
		}
	}
}

func b2u(b bool) byte {
	if b {
		return 1
	}
	return 0
}
