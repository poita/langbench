package regex

import "example.com/regex/syntax"

// The matcher executes a compiled program on an explicit backtracking stack.
// Each instruction is a direct translation of a rule in the matching
// semantics: choice points are pushed by opSplit and resumed, last first,
// when a later instruction fails.

type opcode uint8

const (
	opChar  opcode = iota // consume byte arg
	opAny                 // consume any byte
	opSet                 // consume a byte in sets[arg]
	opBol                 // assert position == 0
	opEol                 // assert position == len(subject)
	opSplit               // try arg first, then alt
	opJmp                 // continue at arg
	opSave                // slots[arg] = position
	opEnd                 // complete group arg: caps = (tmpStart, position)
	opMark                // slots[arg] = position (start of a loop iteration)
	opCheck               // if position == slots[arg] continue at alt, else next
	opMatch               // success
)

type inst struct {
	op  opcode
	arg int32
	alt int32
}

// program is a compiled pattern.
type program struct {
	insts  []inst
	sets   []syntax.CharSet
	groups int // number of capture groups
	slots  int // size of the slot array (see slot layout below)
}

// Slot layout, for G groups (g is 1-based):
//
//	slots[2(g-1)], slots[2(g-1)+1]   capture start and end of group g
//	slots[2G + (g-1)]                start of the group's current attempt
//	slots[3G + r]                    start position of the current iteration of loop r
//
// Every slot is -1 (unset) between matches.
func capStart(g int) int         { return 2 * (g - 1) }
func capEnd(g int) int           { return 2*(g-1) + 1 }
func tmpStart(groups, g int) int { return 2*groups + g - 1 }
