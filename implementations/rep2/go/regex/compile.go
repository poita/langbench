package regexvm

import "errors"

// Opcodes of the backtracking virtual machine.
const (
	opChar     uint8 = iota // match byte ch
	opAny                   // match any byte
	opClass                 // match a byte in class x
	opBol                   // succeed at position 0
	opEol                   // succeed at end of subject
	opSplit                 // try x first, then y
	opJmp                   // continue at x
	opSave                  // slot x = position (trailed)
	opMark                  // loop register x = position (trailed)
	opCheck                 // if position == register x, jump to y
	opCharLoop              // greedy loop over one single-character matcher
	opMatch                 // overall success
)

// Kinds of single-character matcher used by opCharLoop.
const (
	kindChar uint8 = iota
	kindAny
	kindClass
)

// maxProgram bounds the program size so hostile counted quantifiers cannot
// exhaust memory.
const maxProgram = 1 << 21

var errTooLarge = errors.New("regexvm: pattern too large after expanding counted quantifiers")

// inst is one VM instruction. Operand meaning depends on op.
type inst struct {
	op   uint8
	kind uint8 // opCharLoop: matcher kind
	ch   byte  // opChar, opCharLoop with kindChar
	x, y int32 // jump targets, slot numbers or class index
	min  int32 // opCharLoop
	max  int32 // opCharLoop; -1 means unbounded
}

// compiler translates a syntax tree into a flat program.
type compiler struct {
	insts   []inst
	classes []*charSet
	ngroups int
	nregs   int
	err     error
}

func (c *compiler) emit(i inst) int {
	if len(c.insts) >= maxProgram {
		c.err = errTooLarge
		return len(c.insts) - 1
	}
	c.insts = append(c.insts, i)
	return len(c.insts) - 1
}

func (c *compiler) pc() int32 { return int32(len(c.insts)) }

func (c *compiler) classIndex(s *charSet) int32 {
	for i, o := range c.classes {
		if o == s {
			return int32(i)
		}
	}
	c.classes = append(c.classes, s)
	return int32(len(c.classes) - 1)
}

// single emits an instruction matching exactly one character.
func (c *compiler) single(n *node) inst {
	switch n.kind {
	case nLit:
		return inst{op: opChar, ch: n.ch}
	case nAny:
		return inst{op: opAny}
	}
	return inst{op: opClass, x: c.classIndex(n.set)}
}

func (c *compiler) compile(n *node) {
	if c.err != nil {
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
			c.compile(s)
		}
	case nAlt:
		var jumps []int
		for i, b := range n.subs {
			if i == len(n.subs)-1 {
				c.compile(b)
				break
			}
			sp := c.emit(inst{op: opSplit})
			c.insts[sp].x = c.pc()
			c.compile(b)
			jumps = append(jumps, c.emit(inst{op: opJmp}))
			c.insts[sp].y = c.pc()
		}
		for _, j := range jumps {
			c.insts[j].x = c.pc()
		}
	case nGroup:
		c.emit(inst{op: opSave, x: int32(2 * (n.group - 1))})
		c.compile(n.subs[0])
		c.emit(inst{op: opSave, x: int32(2*(n.group-1) + 1)})
	case nRep:
		c.compileRep(n)
	}
}

func (c *compiler) compileRep(n *node) {
	body := n.subs[0]
	if n.max == 0 {
		return // x{0} never runs its atom
	}
	if body.singleChar() {
		if n.min == 1 && n.max == 1 {
			c.emit(c.single(body))
			return
		}
		in := c.single(body)
		switch in.op {
		case opChar:
			in.kind = kindChar
		case opAny:
			in.kind = kindAny
		default:
			in.kind = kindClass
		}
		in.op = opCharLoop
		in.min, in.max = int32(n.min), int32(n.max)
		c.emit(in)
		return
	}
	for i := 0; i < n.min; i++ {
		c.compile(body)
	}
	canBeEmpty := body.nullable()
	if n.max < 0 {
		// L: split body, exit; [mark r]; body; [check r -> exit]; jmp L
		l := c.emit(inst{op: opSplit})
		c.insts[l].x = c.pc()
		reg := c.mark(canBeEmpty)
		c.compile(body)
		chk := c.check(canBeEmpty, reg)
		c.emit(inst{op: opJmp, x: int32(l)})
		exit := c.pc()
		c.insts[l].y = exit
		if chk >= 0 {
			c.insts[chk].y = exit
		}
		return
	}
	var splits, checks []int
	for i := 0; i < n.max-n.min; i++ {
		sp := c.emit(inst{op: opSplit})
		c.insts[sp].x = c.pc()
		splits = append(splits, sp)
		reg := c.mark(canBeEmpty)
		c.compile(body)
		if chk := c.check(canBeEmpty, reg); chk >= 0 {
			checks = append(checks, chk)
		}
		if c.err != nil {
			return
		}
	}
	exit := c.pc()
	for _, s := range splits {
		c.insts[s].y = exit
	}
	for _, k := range checks {
		c.insts[k].y = exit
	}
}

// mark emits a loop-register store when needed and returns the register slot.
func (c *compiler) mark(needed bool) int32 {
	if !needed {
		return -1
	}
	slot := int32(2*c.ngroups + c.nregs)
	c.nregs++
	c.emit(inst{op: opMark, x: slot})
	return slot
}

// check emits the empty-iteration test (target patched by the caller) and
// returns its index, or -1 if none is needed.
func (c *compiler) check(needed bool, reg int32) int {
	if !needed {
		return -1
	}
	return c.emit(inst{op: opCheck, x: reg})
}
