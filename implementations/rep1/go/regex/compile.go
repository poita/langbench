package regex

// maxInsts bounds the size of a compiled program so that nested counted
// quantifiers cannot exhaust memory.
const maxInsts = 2_000_000

type compiler struct {
	prog    []inst
	classes []charset
	nslots  int // 2*(groups+1); loop registers are allocated after these
	nregs   int
	limit   bool
	classID map[*charset]int32 // set -> index in classes, so expanded copies share one entry
}

func (c *compiler) emit(in inst) int {
	c.prog = append(c.prog, in)
	if len(c.prog) > maxInsts {
		c.limit = true
	}
	return len(c.prog) - 1
}

func (c *compiler) pc() int32 { return int32(len(c.prog)) }

func (c *compiler) newRegister() int32 {
	r := int32(c.nslots + c.nregs)
	c.nregs++
	return r
}

// single returns the instruction matching one character for a single-char node.
func (c *compiler) single(n *node) inst {
	switch n.kind {
	case nLit:
		return inst{op: opChar, x: int32(n.ch)}
	case nAny:
		return inst{op: opAny}
	}
	id, ok := c.classID[n.set]
	if !ok {
		id = int32(len(c.classes))
		c.classes = append(c.classes, *n.set)
		c.classID[n.set] = id
	}
	return inst{op: opClass, x: id}
}

func (c *compiler) gen(n *node) {
	if c.limit {
		return
	}
	switch n.kind {
	case nLit, nAny, nClass:
		c.emit(c.single(n))
	case nBol:
		c.emit(inst{op: opBol})
	case nEol:
		c.emit(inst{op: opEol})
	case nSeq:
		for _, s := range n.subs {
			c.gen(s)
		}
	case nAlt:
		var jumps []int
		for i, b := range n.subs {
			if i < len(n.subs)-1 {
				sp := c.emit(inst{op: opSplit})
				c.prog[sp].x = c.pc()
				c.gen(b)
				jumps = append(jumps, c.emit(inst{op: opJmp}))
				c.prog[sp].y = c.pc()
			} else {
				c.gen(b)
			}
		}
		for _, j := range jumps {
			c.prog[j].x = c.pc()
		}
	case nGroup:
		c.emit(inst{op: opSave, x: int32(2 * n.group)})
		c.gen(n.subs[0])
		c.emit(inst{op: opSave, x: int32(2*n.group + 1)})
	case nRep:
		c.genRep(n)
	}
}

func (c *compiler) genRep(n *node) {
	x := n.subs[0]
	if n.max == 0 {
		return // x{0} never runs its atom
	}
	if x.singleChar() {
		sc := c.single(x)
		c.emit(inst{op: opCharLoop, kind: sc.op, x: sc.x, y: int32(n.min), z: int32(n.max)})
		return
	}
	for i := 0; i < n.min && !c.limit; i++ {
		c.gen(x)
	}
	empty := canBeEmpty(x)
	// iteration emits one optional iteration: split body, exit; [mark]; x;
	// [check -> exit]. The returned positions are the operands to patch with
	// the exit address.
	var patchSplit, patchCheck []int
	iteration := func() {
		sp := c.emit(inst{op: opSplit})
		c.prog[sp].x = c.pc()
		patchSplit = append(patchSplit, sp)
		var reg int32
		if empty {
			reg = c.newRegister()
			c.emit(inst{op: opMark, x: reg})
		}
		c.gen(x)
		if empty {
			patchCheck = append(patchCheck, c.emit(inst{op: opCheck, x: reg}))
		}
	}
	if n.max < 0 {
		loop := c.pc()
		iteration()
		c.emit(inst{op: opJmp, x: loop})
	} else {
		for i := n.min; i < n.max && !c.limit; i++ {
			iteration()
		}
	}
	exit := c.pc()
	for _, sp := range patchSplit {
		c.prog[sp].y = exit
	}
	for _, ck := range patchCheck {
		c.prog[ck].y = exit
	}
}
