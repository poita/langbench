// Package bytecode defines the instruction set of the Vellum virtual machine
// and the shape of a compiled program (SPEC.md section 16).
package bytecode

// Op is an opcode.
type Op uint8

// The instruction set. Operands are named A, B and C in Instr.
const (
	PushConst Op = iota // A: constant index
	PushTrue
	PushFalse
	PushUnit
	LoadLocal  // A: slot
	StoreLocal // A: slot
	LoadUpval  // A: upvalue index
	Pop
	Dup
	MakeClosure // A: function, B: number of upvalues
	Call        // A: function, B: argc
	CallValue   // A: argc
	CallBuiltin // A: built-in id, B: argc
	CallMethod  // A: trait, B: method, C: argc (receiver excluded)
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
	Jump        // A: target
	JumpIfFalse // A: target
	JumpIfTrue  // A: target
	MakeList    // A: n
	MakeMap     // A: n entries
	MakeTuple   // A: n
	MakeStruct  // A: decl, B: n
	MakeEnum    // A: decl, B: variant, C: n
	GetField    // A: index
	GetPayload  // A: index
	GetTuple    // A: index
	IndexGet
	IndexSet
	IsVariant // A: variant
	SeqLen
	SeqGet
	ListRest // A: index
	NoMatch
	Panic
	Halt

	// Private instructions used by the compiler for loops.
	SaveSP    // A: slot; remembers the stack height
	RestoreSP // A: slot; restores the stack height (used by break/continue)
	IterNext  // A: index slot, B: sequence slot, C: exit target
)

// Instr is one instruction.
type Instr struct {
	Op      Op
	A, B, C int32
}

// ConstKind is the type of a constant-pool entry.
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
	Kind ConstKind
	I    int64   // Int, Char
	F    float64 // Float
	S    []rune  // Str
}

// Function is a compiled function, method, default body or lambda.
type Function struct {
	Name    string
	NParams int // including self
	NLocals int // parameters plus other local slots
	Code    []Instr
}

// DeclInfo describes a struct or enum declaration.
type DeclInfo struct {
	Name     string
	IsEnum   bool
	Fields   []string  // struct field names
	Variants []Variant // enum variants
}

// Variant describes an enum variant.
type Variant struct {
	Name     string
	NPayload int
}

// ImplEntry is one impl: for the given trait and head constructor, the
// function index of each trait method (defaults filled in).
type ImplEntry struct {
	Trait   int
	Ctor    int
	Methods []int32
}

// Program is a compiled program.
type Program struct {
	Consts    []Const
	Funcs     []*Function
	Decls     []DeclInfo // indexed by declaration id; 0 is Option, 1 is Result
	NumTraits int
	Impls     []ImplEntry
	Main      int
}
