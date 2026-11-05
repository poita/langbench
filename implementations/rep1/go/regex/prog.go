package regex

// opcode identifies a VM instruction.
type opcode uint8

const (
	opChar     opcode = iota // match byte x
	opAny                    // match any byte
	opClass                  // match byte in classes[x]
	opBol                    // succeed at position 0
	opEol                    // succeed at end of subject
	opSplit                  // try x first; on failure resume at y
	opJmp                    // continue at x
	opSave                   // caps[x] = pos (trailed)
	opMark                   // caps[x] = pos (trailed); loop register
	opCheck                  // if caps[x] == pos continue at y, else fall through
	opMatch                  // overall success
	opCharLoop               // repeat single-char matcher kind/x, y..z times (z < 0: unbounded)
)

// inst is one fixed-size VM instruction.
type inst struct {
	op   opcode
	kind opcode // opCharLoop: the single-character matcher (opChar, opAny, opClass)
	x    int32
	y    int32
	z    int32
}
