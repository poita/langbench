/// The bytecode: instruction set and compiled program (SPEC.md section 16).
module langvm.bytecode;

import langvm.value;

/// Opcodes of the stack machine. Operands are `Instr.a`, `.b`, `.c`.
///
/// Differences from the table in SPEC.md 16.2 are purely internal: the
/// pattern-matching instructions (`isVariant`, `seqLen`, `listRest`) pop their
/// operand instead of peeking at it, and `seqGet` is replaced by `indexGet`.
enum Op : ubyte
{
    pushConst, /// a = constant index
    pushTrue,
    pushFalse,
    pushUnit,
    loadLocal, /// a = slot
    storeLocal, /// a = slot (pops)
    loadUpval, /// a = upvalue index
    pop,
    dup,
    makeClosure, /// a = function, b = number of upvalues
    call, /// a = function, b = argc
    callValue, /// a = argc; the closure sits under the arguments
    callBuiltin, /// a = built-in id, b = argc
    callMethod, /// a = trait, b = method, c = argc (receiver under the arguments)
    ret,
    retUnit,
    addI, subI, mulI, divI, modI, negI,
    bnot, band, bor, bxor, shl, shr,
    addF, subF, mulF, divF, negF,
    notB,
    eq, ne, lt, le, gt, ge,
    concatStr, concatList,
    jump, /// a = target
    jumpIfFalse, /// a = target (pops a Bool)
    jumpIfTrue,
    makeList, /// a = n
    makeMap, /// a = n entries (2n values)
    makeTuple, /// a = n
    makeStruct, /// a = declaration id, b = n
    makeEnum, /// a = declaration id, b = variant, c = n
    getField, /// a = index
    getPayload,
    getTuple,
    indexGet,
    indexSet, /// pops value, index, container
    isVariant, /// a = variant; pops an enum value, pushes a Bool
    seqLen, /// pops a list or string, pushes its length
    listRest, /// a = index; pops a list, pushes a new list of the elements from a
    noMatch,
    panic, /// pops a Str
    halt,
}

/// One instruction.
struct Instr
{
    Op op;
    int a, b, c;
}

/// A compiled function, method or lambda.
final class Func
{
    string name;
    int nparams;
    int nlocals;
    Instr[] code;
    /// Whether a call of this function counts towards the frame limit.
    bool counted = true;
}

/// A compiled program, ready to run.
final class Program
{
    Func[] funcs;
    /// The constant pool.
    Value[] consts;
    /// Index of the entry stub, which calls `main` and halts.
    int entry;
    /// `impls[trait][ctor]` lists the function indices of that impl's methods
    /// (with trait defaults filling the gaps); null when there is no impl.
    int[][][] impls;
    /// Declaration ids of the prelude's `Option` and `Result`.
    int optionDecl, resultDecl;
}
