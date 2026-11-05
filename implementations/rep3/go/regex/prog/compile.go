package prog

import (
	"errors"

	"regex/syntax"
)

// MaxInsts bounds the size of a compiled program. Counted quantifiers are
// expanded into copies of their body, so nested counts can blow up.
const MaxInsts = 4_000_000

// ErrTooLarge is returned when a pattern expands past MaxInsts instructions.
var ErrTooLarge = errors.New("regex: compiled program too large")

type compiler struct {
	p   *Program
	err error
}

// Compile translates a syntax tree into a program.
func Compile(t *syntax.Tree) (*Program, error) {
	c := &compiler{p: &Program{NumGroups: t.NumGroups, NumCaps: 2 * t.NumGroups}}
	c.gen(t.Root)
	c.emit(Inst{Op: OpMatch})
	if c.err != nil {
		return nil, c.err
	}
	p := c.p
	p.Anchored = t.Root.Anchored()
	var first syntax.CharSet
	if !t.Root.AddFirst(&first) && !first.IsFull() {
		p.First = &first
	}
	return p, nil
}

func (c *compiler) pc() int { return len(c.p.Insts) }

func (c *compiler) emit(in Inst) int {
	if len(c.p.Insts) >= MaxInsts {
		c.err = ErrTooLarge
		return 0
	}
	c.p.Insts = append(c.p.Insts, in)
	return len(c.p.Insts) - 1
}

func (c *compiler) addSet(s *syntax.CharSet) int32 {
	c.p.Sets = append(c.p.Sets, *s)
	return int32(len(c.p.Sets) - 1)
}

func (c *compiler) newReg() int32 {
	c.p.NumRegs++
	return int32(c.p.NumRegs - 1)
}

func (c *compiler) gen(n *syntax.Node) {
	if c.err != nil {
		return
	}
	switch n.Kind {
	case syntax.KindLiteral:
		c.emit(Inst{Op: OpChar, A: int32(n.Char)})
	case syntax.KindAny:
		c.emit(Inst{Op: OpAny})
	case syntax.KindClass:
		c.emit(Inst{Op: OpClass, A: c.addSet(n.Set)})
	case syntax.KindBOL:
		c.emit(Inst{Op: OpBOL})
	case syntax.KindEOL:
		c.emit(Inst{Op: OpEOL})
	case syntax.KindSeq:
		for _, s := range n.Subs {
			c.gen(s)
		}
	case syntax.KindAlt:
		c.genAlt(n)
	case syntax.KindGroup:
		slot := int32(2 * (n.Index - 1))
		c.emit(Inst{Op: OpSave, A: slot})
		c.gen(n.Subs[0])
		c.emit(Inst{Op: OpSave, A: slot + 1})
	case syntax.KindRep:
		c.genRep(n)
	}
}

// genAlt emits "split L1, L2; branch1; jmp end; L2: split ...; last branch".
func (c *compiler) genAlt(n *syntax.Node) {
	var jumps []int
	for i, b := range n.Subs {
		if i == len(n.Subs)-1 {
			c.gen(b)
			break
		}
		split := c.emit(Inst{Op: OpSplit, A: int32(c.pc() + 1)})
		c.gen(b)
		jumps = append(jumps, c.emit(Inst{Op: OpJmp}))
		if c.err != nil {
			return
		}
		c.p.Insts[split].B = int32(c.pc())
	}
	if c.err != nil {
		return
	}
	end := int32(c.pc())
	for _, j := range jumps {
		c.p.Insts[j].A = end
	}
}

func (c *compiler) genRep(n *syntax.Node) {
	x := n.Subs[0]
	if n.Max == 0 {
		return // x{0}: never runs x
	}
	if x.IsSingleChar() {
		in := Inst{Op: OpCharLoop, B: int32(n.Min), C: int32(n.Max)}
		switch x.Kind {
		case syntax.KindAny:
			in.A = -1
		case syntax.KindLiteral:
			var s syntax.CharSet
			s.Add(x.Char)
			in.A = c.addSet(&s)
		default:
			in.A = c.addSet(x.Set)
		}
		c.emit(in)
		return
	}
	// Mandatory iterations run even when they match the empty string.
	for i := 0; i < n.Min; i++ {
		c.gen(x)
	}
	guard := x.Nullable() // only then can an iteration be empty
	if n.Max == syntax.Unbounded {
		// L: split body, exit; [mark r]; x; [check r -> exit]; jmp L
		loop := c.pc()
		split := c.emit(Inst{Op: OpSplit, A: int32(loop + 1)})
		var reg int32
		if guard {
			reg = c.newReg()
			c.emit(Inst{Op: OpMark, A: reg})
		}
		c.gen(x)
		check := -1
		if guard {
			check = c.emit(Inst{Op: OpCheck, A: reg})
		}
		c.emit(Inst{Op: OpJmp, A: int32(loop)})
		if c.err != nil {
			return
		}
		exit := int32(c.pc())
		c.p.Insts[split].B = exit
		if check >= 0 {
			c.p.Insts[check].B = exit
		}
		return
	}
	// Finite max: max-min nested optional copies sharing one exit.
	var splits, checks []int
	for i := n.Min; i < n.Max; i++ {
		split := c.emit(Inst{Op: OpSplit, A: int32(c.pc() + 1)})
		splits = append(splits, split)
		var reg int32
		if guard {
			reg = c.newReg()
			c.emit(Inst{Op: OpMark, A: reg})
		}
		c.gen(x)
		if guard {
			checks = append(checks, c.emit(Inst{Op: OpCheck, A: reg}))
		}
		if c.err != nil {
			return
		}
	}
	exit := int32(c.pc())
	for _, s := range splits {
		c.p.Insts[s].B = exit
	}
	for _, k := range checks {
		c.p.Insts[k].B = exit
	}
}
