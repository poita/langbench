package regex

import (
	"errors"

	"example.com/regex/syntax"
)

// maxInsts bounds the size of a compiled program. Counted repetitions are
// expanded into copies of their operand, so deeply nested counts can
// otherwise grow without limit.
const maxInsts = 1 << 20

// ErrTooLarge is returned by Compile when counted repetitions expand into a
// program larger than the implementation limit.
var ErrTooLarge = errors.New("regex: pattern too large after expanding repetitions")

type compiler struct {
	prog   *program
	marks  int
	failed bool
}

func compile(root *syntax.Node, groups int) (*program, error) {
	c := &compiler{prog: &program{groups: groups}}
	c.emit(root)
	c.add(inst{op: opMatch})
	if c.failed {
		return nil, ErrTooLarge
	}
	c.prog.slots = 3*groups + c.marks
	return c.prog, nil
}

// add appends an instruction and returns its index.
func (c *compiler) add(i inst) int {
	if len(c.prog.insts) >= maxInsts {
		c.failed = true
		return 0
	}
	c.prog.insts = append(c.prog.insts, i)
	return len(c.prog.insts) - 1
}

func (c *compiler) pc() int32 { return int32(len(c.prog.insts)) }

func (c *compiler) emit(n *syntax.Node) {
	if c.failed {
		return
	}
	switch n.Kind {
	case syntax.Empty:
	case syntax.Literal:
		c.add(inst{op: opChar, arg: int32(n.Char)})
	case syntax.AnyChar:
		c.add(inst{op: opAny})
	case syntax.Class:
		c.prog.sets = append(c.prog.sets, n.Set)
		c.add(inst{op: opSet, arg: int32(len(c.prog.sets) - 1)})
	case syntax.StartAnchor:
		c.add(inst{op: opBol})
	case syntax.EndAnchor:
		c.add(inst{op: opEol})
	case syntax.Concat:
		for _, s := range n.Subs {
			c.emit(s)
		}
	case syntax.Alternate:
		c.emitAlternate(n)
	case syntax.Group:
		c.add(inst{op: opSave, arg: int32(tmpStart(c.prog.groups, n.Index))})
		c.emit(n.Subs[0])
		c.add(inst{op: opEnd, arg: int32(n.Index)})
	case syntax.Repeat:
		c.emitRepeat(n)
	}
}

// emitAlternate lays out  split L1,L2; L1: b1; jmp end; L2: split ...; bn; end:
func (c *compiler) emitAlternate(n *syntax.Node) {
	var jumps []int
	for i, b := range n.Subs {
		if i == len(n.Subs)-1 {
			c.emit(b)
			break
		}
		split := c.add(inst{op: opSplit, arg: c.pc() + 1})
		c.emit(b)
		jumps = append(jumps, c.add(inst{op: opJmp}))
		if !c.failed {
			c.prog.insts[split].alt = c.pc()
		}
	}
	if c.failed {
		return
	}
	for _, j := range jumps {
		c.prog.insts[j].arg = c.pc()
	}
}

// emitRepeat expands x{min,max} by copying the operand: min mandatory copies
// (which run even when they match empty), then either a loop (max unbounded)
// or max-min nested optional copies. An optional copy that matches the empty
// string ends the repetition, which is what opMark/opCheck implement.
func (c *compiler) emitRepeat(n *syntax.Node) {
	x := n.Subs[0]
	for i := 0; i < n.Min && !c.failed; i++ {
		c.emit(x)
	}
	if n.Max == 0 || c.failed {
		return
	}
	reg := -1
	if x.CanBeEmpty() {
		reg = 3*c.prog.groups + c.marks
		c.marks++
	}
	var exits []int // instructions whose alt must point past the repetition
	optionalCopy := func() int {
		split := c.add(inst{op: opSplit, arg: c.pc() + 1})
		exits = append(exits, split)
		if reg >= 0 {
			c.add(inst{op: opMark, arg: int32(reg)})
		}
		c.emit(x)
		if reg >= 0 {
			exits = append(exits, c.add(inst{op: opCheck, arg: int32(reg)}))
		}
		return split
	}
	if n.Max == syntax.Unbounded {
		loop := optionalCopy()
		c.add(inst{op: opJmp, arg: int32(loop)})
	} else {
		for i := n.Min; i < n.Max && !c.failed; i++ {
			optionalCopy()
		}
	}
	if c.failed {
		return
	}
	end := c.pc()
	for _, e := range exits {
		c.prog.insts[e].alt = end
	}
}
