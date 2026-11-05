/// The bytecode instruction set and the compiled program representation.
module langvm.bytecode;

import langvm.value;

/// Opcodes. Operands follow the opcode inline in the code array.
enum Op : int
{
    pushConst, // k
    pushTrue,
    pushFalse,
    pushUnit,
    loadLocal, // slot
    storeLocal, // slot
    loadUpval, // index
    pop,
    dup,
    makeClosure, // fn, n
    call, // fn, argc
    callValue, // argc
    callBuiltin, // builtin, argc
    callMethod, // trait, method, argc
    ret,
    retUnit,
    addI, subI, mulI, divI, modI, negI, bnot, band, bor, bxor, shl, shr,
    addF, subF, mulF, divF, negF,
    notB,
    eq, ne, lt, le, gt, ge,
    concatStr, concatList,
    jump, // target
    jumpIfFalse, // target
    jumpIfTrue, // target
    makeList, // n
    makeMap, // n
    makeTuple, // n
    makeStruct, // decl, n
    makeEnum, // decl, variant, n
    getField, // i
    getPayload, // i
    getTuple, // i
    indexGet,
    indexSet,
    noMatch,
    // fused forms (slot based tests and loop helpers)
    jumpUnlessVariant, // slot, variant, target
    jumpUnlessLen, // slot, n, target
    jumpUnlessLenGe, // slot, n, target
    pushPayload, // slot, i
    pushField, // slot, i
    pushTuple, // slot, i
    pushElem, // slot, i
    listRest, // slot, i
    seqLen, // slot
    seqGet, // slot, indexSlot
    incLocal, // slot
}

/// Number of inline operands of each opcode.
int operandCount(Op op) pure nothrow @nogc
{
    final switch (op)
    {
    case Op.pushTrue, Op.pushFalse, Op.pushUnit, Op.pop, Op.dup, Op.ret, Op.retUnit,
        Op.addI, Op.subI, Op.mulI, Op.divI, Op.modI, Op.negI, Op.bnot, Op.band, Op.bor,
        Op.bxor, Op.shl, Op.shr, Op.addF, Op.subF, Op.mulF, Op.divF, Op.negF, Op.notB,
        Op.eq, Op.ne, Op.lt, Op.le, Op.gt, Op.ge, Op.concatStr, Op.concatList,
        Op.indexGet, Op.indexSet, Op.noMatch:
        return 0;
    case Op.pushConst, Op.loadLocal, Op.storeLocal, Op.loadUpval, Op.callValue,
        Op.jump, Op.jumpIfFalse, Op.jumpIfTrue, Op.makeList, Op.makeMap, Op.makeTuple,
        Op.getField, Op.getPayload, Op.getTuple, Op.seqLen, Op.incLocal:
        return 1;
    case Op.makeClosure, Op.call, Op.callBuiltin, Op.makeStruct, Op.pushPayload,
        Op.pushField, Op.pushTuple, Op.pushElem, Op.listRest, Op.seqGet:
        return 2;
    case Op.callMethod, Op.makeEnum, Op.jumpUnlessVariant, Op.jumpUnlessLen, Op.jumpUnlessLenGe:
        return 3;
    }
}

/// A compiled function (declaration, method, default method body, or lambda).
final class FuncCode
{
    string name;
    int nparams;
    int nslots;
    int maxStack;
    int[] code;
}

/// A compiled program.
final class Program
{
    FuncCode[] funcs;
    Value[] consts;
    int mainFn;
    /// `methodTable[trait][headCtor][method]` = function index (or -1).
    int[][][] methodTable;
    /// Shared payload-less enum values: `unitVariants[enumDecl][variant]`.
    Value[][] unitVariants;
    /// Number of declarations (struct/enum).
    int declCount;
}
