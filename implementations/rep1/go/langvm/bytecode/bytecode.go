// Package bytecode defines the instruction set and the compiled program of
// the Vellum virtual machine (SPEC section 16).
package bytecode

// Op is an opcode.
type Op uint8

// Opcodes. Operands are in Instr.A, B and C as described per opcode.
const (
	PushConst Op = iota // A=const index
	PushTrue
	PushFalse
	PushUnit
	LoadLocal  // A=slot
	StoreLocal // A=slot (pops)
	LoadUpval  // A=upvalue index
	Pop
	Dup
	MakeClosure // A=function, B=number of captured values (popped)
	Call        // A=function, B=argc
	CallValue   // A=argc (closure sits under the arguments)
	CallBuiltin // A=built-in id, B=argc
	CallMethod  // A=trait id, B=method index, C=argc (receiver under the arguments)
	Ret
	RetUnit

	AddI
	SubI
	MulI
	DivI
	ModI
	NegI
	BNot
	BAnd
	BOr
	BXor
	Shl
	Shr
	AddF
	SubF
	MulF
	DivF
	NegF
	NotB
	Eq
	Ne
	Lt
	Le
	Gt
	Ge
	ConcatStr
	ConcatList

	Jump        // A=target
	JumpIfFalse // A=target (pops a Bool)
	JumpIfTrue  // A=target (pops a Bool)

	MakeList   // A=n
	MakeMap    // A=number of entries (pops 2n values)
	MakeTuple  // A=n
	MakeStruct // A=declaration, B=n
	MakeEnum   // A=declaration, B=variant, C=n
	GetField   // A=index
	GetPayload // A=index
	GetTuple   // A=index
	IndexGet
	IndexSet // pops value, index, container
	NoMatch
	Panic // pops a Str
	Halt

	// Fused forms (APPROACH.md item 6).
	JumpUnlessVariant // A=slot, B=variant, C=target
	JumpUnlessLen     // A=slot, B=n, C=target (list length == n)
	JumpUnlessLenGE   // A=slot, B=n, C=target (list length >= n)
	PushPayload       // A=slot, B=index
	PushField         // A=slot, B=index
	PushTuple         // A=slot, B=index
	PushElem          // A=slot, B=index (list element)
	PushRest          // A=slot, B=index (new list of elements from index)
	SeqLenSlot        // A=slot (list or string)
	SeqGetSlot        // A=sequence slot, B=index slot
	IncLocal          // A=slot
)

var opNames = [...]string{
	"PUSH_CONST", "PUSH_TRUE", "PUSH_FALSE", "PUSH_UNIT", "LOAD_LOCAL", "STORE_LOCAL",
	"LOAD_UPVAL", "POP", "DUP", "MAKE_CLOSURE", "CALL", "CALL_VALUE", "CALL_BUILTIN",
	"CALL_METHOD", "RET", "RET_UNIT", "ADD_I", "SUB_I", "MUL_I", "DIV_I", "MOD_I",
	"NEG_I", "BNOT", "BAND", "BOR", "BXOR", "SHL", "SHR", "ADD_F", "SUB_F", "MUL_F",
	"DIV_F", "NEG_F", "NOT_B", "EQ", "NE", "LT", "LE", "GT", "GE", "CONCAT_STR",
	"CONCAT_LIST", "JUMP", "JUMP_IF_FALSE", "JUMP_IF_TRUE", "MAKE_LIST", "MAKE_MAP",
	"MAKE_TUPLE", "MAKE_STRUCT", "MAKE_ENUM", "GET_FIELD", "GET_PAYLOAD", "GET_TUPLE",
	"INDEX_GET", "INDEX_SET", "NO_MATCH", "PANIC", "HALT", "JUMP_UNLESS_VARIANT",
	"JUMP_UNLESS_LEN", "JUMP_UNLESS_LEN_GE", "PUSH_PAYLOAD", "PUSH_FIELD", "PUSH_TUPLE",
	"PUSH_ELEM", "PUSH_REST", "SEQ_LEN_SLOT", "SEQ_GET_SLOT", "INC_LOCAL",
}

// String returns the mnemonic of an opcode.
func (o Op) String() string {
	if int(o) < len(opNames) {
		return opNames[o]
	}
	return "?"
}

// Instr is one fixed-format instruction.
type Instr struct {
	Op      Op
	A, B, C int32
}

// ConstKind tags a constant-pool entry.
type ConstKind uint8

// Constant kinds.
const (
	ConstInt ConstKind = iota
	ConstFloat
	ConstChar
	ConstStr
)

// Const is a constant-pool entry.
type Const struct {
	Kind  ConstKind
	Int   int64 // Int and Char
	Float float64
	Str   []rune
}

// Func is one compiled function, method, default body or lambda.
type Func struct {
	Name     string
	NParams  int // includes self for methods
	NSlots   int // parameters plus locals
	MaxStack int // upper bound on the operand stack depth
	Code     []Instr
}

// TypeInfo describes a struct or enum declaration.
type TypeInfo struct {
	Name     string
	IsEnum   bool
	NFields  int
	Variants []VariantInfo
}

// VariantInfo describes an enum variant.
type VariantInfo struct {
	Name     string
	NPayload int
}

// Program is a compiled program.
type Program struct {
	Consts   []Const
	Funcs    []*Func
	Types    []TypeInfo
	Main     int
	NumCtors int
	NumTrait int
	// Methods[trait*NumCtors+ctor] lists, per trait method index, the
	// function implementing it for that head constructor; nil if no impl.
	Methods [][]int32
}
