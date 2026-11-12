package chip8

// execute performs one already-fetched instruction. PC points past op.
func (m *Machine) execute(op uint16) {
	x := (op >> 8) & 0xF
	y := (op >> 4) & 0xF
	n := op & 0xF
	nn := byte(op)
	nnn := op & 0xFFF
	v := &m.V

	switch op >> 12 {
	case 0x0:
		switch op {
		case 0x00E0:
			m.Display.Clear()
		case 0x00EE:
			// Returning from an empty stack is unspecified; ignore it.
			if m.SP > 0 {
				m.SP--
				m.PC = m.Stack[m.SP] & 0xFFF
			}
		}
	case 0x1:
		m.PC = nnn
	case 0x2:
		// Pushing onto a full stack is unspecified; skip the push.
		if m.SP < StackDepth {
			m.Stack[m.SP] = m.PC
			m.SP++
		}
		m.PC = nnn
	case 0x3:
		if v[x] == nn {
			m.skip()
		}
	case 0x4:
		if v[x] != nn {
			m.skip()
		}
	case 0x5:
		if n == 0 && v[x] == v[y] {
			m.skip()
		}
	case 0x6:
		v[x] = nn
	case 0x7:
		v[x] += nn
	case 0x8:
		m.alu(x, y, n)
	case 0x9:
		if n == 0 && v[x] != v[y] {
			m.skip()
		}
	case 0xA:
		m.I = nnn
	case 0xB:
		m.PC = (nnn + uint16(v[0])) & 0xFFF
	case 0xC:
		v[x] = m.rng.next() & nn
	case 0xD:
		m.draw(x, y, n)
	case 0xE:
		switch nn {
		case 0x9E:
			if m.keys&(1<<(v[x]&0xF)) != 0 {
				m.skip()
			}
		case 0xA1:
			if m.keys&(1<<(v[x]&0xF)) == 0 {
				m.skip()
			}
		}
	case 0xF:
		m.misc(x, nn)
	}
}

func (m *Machine) skip() { m.PC = (m.PC + 2) & 0xFFF }

// alu executes the 8XYN arithmetic and logic group. The result is written to
// VX before the flag is written to VF, so the flag wins when X is F.
func (m *Machine) alu(x, y, n uint16) {
	v := &m.V
	vx, vy := v[x], v[y]
	switch n {
	case 0x0:
		v[x] = vy
	case 0x1:
		v[x] = vx | vy
	case 0x2:
		v[x] = vx & vy
	case 0x3:
		v[x] = vx ^ vy
	case 0x4:
		sum := uint16(vx) + uint16(vy)
		v[x] = byte(sum)
		v[0xF] = b2b(sum > 255)
	case 0x5:
		v[x] = vx - vy
		v[0xF] = b2b(vx >= vy)
	case 0x6:
		v[x] = vx >> 1
		v[0xF] = vx & 1
	case 0x7:
		v[x] = vy - vx
		v[0xF] = b2b(vy >= vx)
	case 0xE:
		v[x] = vx << 1
		v[0xF] = vx >> 7
	}
}

// draw executes DXYN.
func (m *Machine) draw(x, y, n uint16) {
	sx := int(m.V[x] & 63)
	sy := int(m.V[y] & 31)
	var rows [15]byte
	for r := uint16(0); r < n; r++ {
		rows[r] = m.Mem[(m.I+r)&0xFFF]
	}
	m.V[0xF] = b2b(m.Display.drawSprite(sx, sy, rows[:n]))
}

// misc executes the FXNN group.
func (m *Machine) misc(x uint16, nn byte) {
	v := &m.V
	switch nn {
	case 0x07:
		v[x] = m.DT
	case 0x0A:
		if m.keys == 0 {
			m.PC = (m.PC - 2) & 0xFFF
			return
		}
		for k := byte(0); k < 16; k++ {
			if m.keys&(1<<k) != 0 {
				v[x] = k
				return
			}
		}
	case 0x15:
		m.DT = v[x]
	case 0x18:
		m.ST = v[x]
	case 0x1E:
		m.I += uint16(v[x])
	case 0x29:
		m.I = FontBase + uint16(v[x]&0xF)*GlyphSize
	case 0x33:
		val := v[x]
		m.Mem[m.I&0xFFF] = val / 100
		m.Mem[(m.I+1)&0xFFF] = (val / 10) % 10
		m.Mem[(m.I+2)&0xFFF] = val % 10
	case 0x55:
		for k := uint16(0); k <= x; k++ {
			m.Mem[(m.I+k)&0xFFF] = v[k]
		}
	case 0x65:
		for k := uint16(0); k <= x; k++ {
			v[k] = m.Mem[(m.I+k)&0xFFF]
		}
	}
}

func b2b(b bool) byte {
	if b {
		return 1
	}
	return 0
}
