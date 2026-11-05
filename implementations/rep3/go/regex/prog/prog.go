// Package prog defines the flat instruction set of the backtracking virtual
// machine and compiles syntax trees into programs for it.
package prog

import (
	"fmt"
	"strings"

	"regex/syntax"
)

// Op is an instruction opcode.
type Op uint8

// Opcodes. Operand meanings are listed per opcode.
const (
	OpChar     Op = iota // A = byte to match
	OpAny                // match any one character
	OpClass              // A = index into Program.Sets
	OpBOL                // succeed only at position 0
	OpEOL                // succeed only at the end of the subject
	OpSplit              // try A first; B is the alternative (pushed as a choice point)
	OpJmp                // continue at A
	OpSave               // A = capture slot; record the position (trailed)
	OpMark               // A = loop register; record the position (trailed)
	OpCheck              // A = loop register, B = target: jump to B if the position equals the register
	OpCharLoop           // A = set index (-1 = any char), B = min, C = max (-1 = unbounded)
	OpMatch              // overall success
)

// Inst is a single fixed-size instruction.
type Inst struct {
	Op      Op
	A, B, C int32
}

// Program is a compiled pattern.
type Program struct {
	Insts []Inst
	Sets  []syntax.CharSet // class tables referenced by OpClass and OpCharLoop

	NumGroups int // number of capture groups
	NumCaps   int // capture slots: 2 per group (slot 2(g-1) is the start of group g)
	NumRegs   int // loop registers, stored after the capture slots

	// Anchored is true when every match must start at position 0.
	Anchored bool
	// First, when non-nil, is the set of characters a match can begin with;
	// start positions whose character is outside it can be skipped. It is nil
	// when the pattern is nullable or the set is every character.
	First *syntax.CharSet
}

// String returns a human-readable disassembly of the program.
func (p *Program) String() string {
	var b strings.Builder
	for i, in := range p.Insts {
		fmt.Fprintf(&b, "%4d  ", i)
		switch in.Op {
		case OpChar:
			fmt.Fprintf(&b, "char %q", rune(in.A))
		case OpAny:
			b.WriteString("any")
		case OpClass:
			fmt.Fprintf(&b, "class #%d", in.A)
		case OpBOL:
			b.WriteString("bol")
		case OpEOL:
			b.WriteString("eol")
		case OpSplit:
			fmt.Fprintf(&b, "split %d, %d", in.A, in.B)
		case OpJmp:
			fmt.Fprintf(&b, "jmp %d", in.A)
		case OpSave:
			fmt.Fprintf(&b, "save %d", in.A)
		case OpMark:
			fmt.Fprintf(&b, "mark r%d", in.A)
		case OpCheck:
			fmt.Fprintf(&b, "check r%d -> %d", in.A, in.B)
		case OpCharLoop:
			fmt.Fprintf(&b, "charloop set=%d min=%d max=%d", in.A, in.B, in.C)
		case OpMatch:
			b.WriteString("match")
		}
		b.WriteByte('\n')
	}
	return b.String()
}
