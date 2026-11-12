package regexbt

import "example.com/regexbt/syntax"

// opcode is the operation of a single instruction of a compiled program.
type opcode uint8

const (
	opChar     opcode = iota // consume byte c
	opAny                    // consume any byte
	opSet                    // consume a byte contained in set
	opBol                    // assert pos == 0
	opEol                    // assert pos == len(subject)
	opSplit                  // try x first; on failure resume at y
	opJmp                    // goto x
	opMark                   // reg[x] = pos (undoable)
	opClose                  // caps of group x = (reg[y], pos) (undoable)
	opEmptyChk               // if pos == reg[x] goto y (empty optional iteration)
	opMatch                  // success
)

// inst is one instruction of the backtracking program.
type inst struct {
	op   opcode
	c    byte
	x, y int32
	set  *syntax.CharSet
}

// prog is a compiled pattern. Registers are laid out as
//
//	[0, 2*(G+1))              capture pairs (group g at 2g, 2g+1)
//	[2*(G+1), 3*(G+1))        pending start position of each group
//	[3*(G+1), nregs)          per-loop iteration start positions
type prog struct {
	insts  []inst
	ngroup int
	nregs  int
}
