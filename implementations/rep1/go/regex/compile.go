package regexbt

import (
	"errors"

	"example.com/regexbt/syntax"
)

// maxProgSize bounds the number of instructions a pattern may expand to.
const maxProgSize = 1 << 20

var errTooLarge = errors.New("regex: pattern too large after expanding counted repetitions")

type compiler struct {
	p      prog
	tooBig bool
}

// compile translates a syntax tree into a backtracking program.
func compile(root *syntax.Node, ngroups int) (*prog, error) {
	c := &compiler{}
	c.p.ngroup = ngroups
	c.p.nregs = 3 * (ngroups + 1)
	c.emit(root)
	c.add(inst{op: opMatch})
	if c.tooBig {
		return nil, errTooLarge
	}
	return &c.p, nil
}

func (c *compiler) pc() int32 { return int32(len(c.p.insts)) }

func (c *compiler) add(in inst) int32 {
	if len(c.p.insts) >= maxProgSize {
		c.tooBig = true
		return 0 // keep going harmlessly; compile() reports the error
	}
	c.p.insts = append(c.p.insts, in)
	return int32(len(c.p.insts) - 1)
}

func (c *compiler) newReg() int32 {
	c.p.nregs++
	return int32(c.p.nregs - 1)
}

// patch sets field y of the instruction at index i.
func (c *compiler) patchY(i int32, y int32) {
	if !c.tooBig {
		c.p.insts[i].y = y
	}
}

func (c *compiler) emit(n *syntax.Node) {
	if c.tooBig {
		return
	}
	switch n.Kind {
	case syntax.KindEmpty:
	case syntax.KindLiteral:
		c.add(inst{op: opChar, c: n.Char})
	case syntax.KindAny:
		c.add(inst{op: opAny})
	case syntax.KindClass:
		set := n.Set
		c.add(inst{op: opSet, set: &set})
	case syntax.KindBol:
		c.add(inst{op: opBol})
	case syntax.KindEol:
		c.add(inst{op: opEol})
	case syntax.KindConcat:
		for _, s := range n.Subs {
			c.emit(s)
		}
	case syntax.KindAlternate:
		c.emitAlternate(n)
	case syntax.KindGroup:
		g := int32(n.Group)
		startReg := int32(2*(c.p.ngroup+1)) + g
		c.add(inst{op: opMark, x: startReg})
		c.emit(n.Subs[0])
		c.add(inst{op: opClose, x: g, y: startReg})
	case syntax.KindRepeat:
		c.emitRepeat(n)
	}
}

// emitAlternate lays out b1 | b2 | ... | bn as
//
//	split L1, L2; L1: b1; jmp end; L2: split ...; Ln: bn; end:
func (c *compiler) emitAlternate(n *syntax.Node) {
	var jumps []int32
	for i, b := range n.Subs {
		if i == len(n.Subs)-1 {
			c.emit(b)
			break
		}
		split := c.add(inst{op: opSplit})
		c.p.insts[split].x = c.pc()
		c.emit(b)
		jumps = append(jumps, c.add(inst{op: opJmp}))
		c.patchY(split, c.pc())
	}
	end := c.pc()
	for _, j := range jumps {
		if !c.tooBig {
			c.p.insts[j].x = end
		}
	}
}

// emitRepeat expands x{min,max} following the rep() function of the spec:
// min mandatory copies of x, then either an unbounded loop or max-min
// optional copies. Every optional iteration is guarded by an empty check:
// an iteration that consumed nothing leaves the repetition immediately.
func (c *compiler) emitRepeat(n *syntax.Node) {
	sub := n.Subs[0]
	for i := 0; i < n.Min; i++ {
		c.emit(sub)
		if c.tooBig {
			return
		}
	}
	if n.Max == syntax.Unbounded {
		reg := c.newReg()
		loop := c.add(inst{op: opSplit})
		c.p.insts[loop].x = c.pc()
		c.add(inst{op: opMark, x: reg})
		c.emit(sub)
		chk := c.add(inst{op: opEmptyChk, x: reg})
		c.add(inst{op: opJmp, x: loop})
		exit := c.pc()
		c.patchY(loop, exit)
		c.patchY(chk, exit)
		return
	}
	if n.Max <= n.Min {
		return
	}
	reg := c.newReg()
	var splits, chks []int32
	for i := n.Min; i < n.Max; i++ {
		split := c.add(inst{op: opSplit})
		c.p.insts[split].x = c.pc()
		splits = append(splits, split)
		c.add(inst{op: opMark, x: reg})
		c.emit(sub)
		if c.tooBig {
			return
		}
		chks = append(chks, c.add(inst{op: opEmptyChk, x: reg}))
	}
	exit := c.pc()
	for _, i := range splits {
		c.patchY(i, exit)
	}
	for _, i := range chks {
		c.patchY(i, exit)
	}
}
