/// The stack virtual machine.
module langvm.vm;

import langvm.bytecode;
import langvm.model : HeadCtor;
import langvm.diag;
import langvm.value;

/// Signature of a built-in function implemented in the host.
alias BuiltinFn = Value function(VM vm, Value[] args);

/// Maximum number of simultaneously active frames.
enum maxFrames = 20000;

private struct Frame
{
    int fn;
    int pc;
    int base;
    int spReset;
    ClosureObj clo;
}

/// The virtual machine: value stack, frames, output buffer and the dispatch loop.
final class VM
{
    Program prog;
    BuiltinFn[] builtins;
    Value[] stack;
    private Frame[] frames;
    private int nframes;
    private int sp;
    /// Bytes written by `print` and `emit` (UTF-8).
    ubyte[] output;
    private size_t outLen;

    this(Program prog, BuiltinFn[] builtins)
    {
        this.prog = prog;
        this.builtins = builtins;
        stack = new Value[1 << 18];
        frames = new Frame[maxFrames + 1];
        output = new ubyte[1 << 16];
    }

    /// The bytes written so far.
    const(ubyte)[] written() const
    {
        return output[0 .. outLen];
    }

    // ---------------------------------------------------------------- output

    private void ensureOut(size_t extra)
    {
        if (outLen + extra > output.length)
        {
            size_t n = output.length * 2;
            while (n < outLen + extra)
                n *= 2;
            auto nb = new ubyte[n];
            nb[0 .. outLen] = output[0 .. outLen];
            output = nb;
        }
    }

    /// Appends a string (scalar values) encoded as UTF-8.
    void write(const(dchar)[] s)
    {
        ensureOut(s.length * 4);
        size_t o = outLen;
        auto buf = output;
        foreach (c; s)
        {
            if (c < 0x80)
                buf[o++] = cast(ubyte) c;
            else if (c < 0x800)
            {
                buf[o++] = cast(ubyte)(0xC0 | (c >> 6));
                buf[o++] = cast(ubyte)(0x80 | (c & 0x3F));
            }
            else if (c < 0x10000)
            {
                buf[o++] = cast(ubyte)(0xE0 | (c >> 12));
                buf[o++] = cast(ubyte)(0x80 | ((c >> 6) & 0x3F));
                buf[o++] = cast(ubyte)(0x80 | (c & 0x3F));
            }
            else
            {
                buf[o++] = cast(ubyte)(0xF0 | (c >> 18));
                buf[o++] = cast(ubyte)(0x80 | ((c >> 12) & 0x3F));
                buf[o++] = cast(ubyte)(0x80 | ((c >> 6) & 0x3F));
                buf[o++] = cast(ubyte)(0x80 | (c & 0x3F));
            }
        }
        outLen = o;
    }

    /// Appends ASCII/UTF-8 text.
    void writeText(const(char)[] s)
    {
        ensureOut(s.length);
        output[outLen .. outLen + s.length] = cast(const(ubyte)[]) s;
        outLen += s.length;
    }

    // ---------------------------------------------------------------- frames

    private void growStack(size_t need)
    {
        size_t n = stack.length * 2;
        while (n < need)
            n *= 2;
        auto ns = new Value[n];
        ns[0 .. stack.length] = stack[];
        stack = ns;
    }

    private void pushFrame(int fn, int base, int spReset, ClosureObj clo)
    {
        if (nframes >= maxFrames)
            panic("call stack overflow");
        auto fc = prog.funcs[fn];
        size_t need = base + fc.nslots + fc.maxStack + 8;
        if (need > stack.length)
            growStack(need);
        frames[nframes++] = Frame(fn, 0, base, spReset, clo);
        sp = base + fc.nslots;
    }

    /// Runs `main` to completion (or until a panic is thrown as [Panic]).
    void runMain()
    {
        nframes = 0;
        sp = 0;
        pushFrame(prog.mainFn, 0, 0, null);
        execute(0);
    }

    /// Calls closure `f` with `args` from host code (used by built-ins such as `sortBy`).
    Value callClosure(Value f, const(Value)[] args)
    {
        auto co = asClosure(f);
        int s = sp;
        if (s + args.length + 1 + 8 > stack.length)
            growStack(s + args.length + 1 + 8);
        stack[s] = f;
        foreach (i, a; args)
            stack[s + 1 + i] = a;
        int stop = nframes;
        pushFrame(co.fn, s + 1, s, co);
        return execute(stop);
    }

    private static int ctorOf(in Value v) pure nothrow @nogc
    {
        final switch (v.t)
        {
        case VT.int_:
            return HeadCtor.int_;
        case VT.float_:
            return HeadCtor.float_;
        case VT.bool_:
            return HeadCtor.bool_;
        case VT.char_:
            return HeadCtor.char_;
        case VT.str:
            return HeadCtor.str;
        case VT.unit:
            return HeadCtor.unit;
        case VT.list:
            return HeadCtor.list;
        case VT.map:
            return HeadCtor.map;
        case VT.strukt, VT.enum_:
            return HeadCtor.firstData + asAgg(v).decl;
        case VT.tuple, VT.closure:
            return -1;
        }
    }

    // ---------------------------------------------------------------- the dispatch loop

    private Value execute(int stopFrames)
    {
        Frame* fr = &frames[nframes - 1];
        FuncCode fc = prog.funcs[fr.fn];
        int[] code = fc.code;
        int pc = fr.pc;
        int base = fr.base;
        ClosureObj clo = fr.clo;
        Value[] st = stack;
        int sp = this.sp;
        const(Value)[] consts = prog.consts;

        while (true)
        {
            final switch (cast(Op) code[pc++])
            {
            case Op.pushConst:
                st[sp++] = consts[code[pc++]];
                break;
            case Op.pushTrue:
                st[sp++] = Value.bool_(true);
                break;
            case Op.pushFalse:
                st[sp++] = Value.bool_(false);
                break;
            case Op.pushUnit:
                st[sp++] = Value.unit;
                break;
            case Op.loadLocal:
                st[sp++] = st[base + code[pc++]];
                break;
            case Op.storeLocal:
                st[base + code[pc++]] = st[--sp];
                break;
            case Op.loadUpval:
                st[sp++] = clo.up[code[pc++]];
                break;
            case Op.pop:
                sp--;
                break;
            case Op.dup:
                st[sp] = st[sp - 1];
                sp++;
                break;
            case Op.makeClosure:
                {
                    int f = code[pc++];
                    int n = code[pc++];
                    Value[] up = n == 0 ? null : st[sp - n .. sp].dup;
                    sp -= n;
                    st[sp++] = Value.obj(VT.closure, new ClosureObj(f, up));
                    break;
                }
            case Op.call:
                {
                    int f = code[pc];
                    int argc = code[pc + 1];
                    pc += 2;
                    fr.pc = pc;
                    this.sp = sp;
                    pushFrame(f, sp - argc, sp - argc, null);
                    st = stack;
                    fr = &frames[nframes - 1];
                    fc = prog.funcs[f];
                    code = fc.code;
                    pc = 0;
                    base = fr.base;
                    clo = null;
                    sp = this.sp;
                    break;
                }
            case Op.callValue:
                {
                    int argc = code[pc++];
                    fr.pc = pc;
                    auto co = asClosure(st[sp - argc - 1]);
                    this.sp = sp;
                    pushFrame(co.fn, sp - argc, sp - argc - 1, co);
                    st = stack;
                    fr = &frames[nframes - 1];
                    fc = prog.funcs[co.fn];
                    code = fc.code;
                    pc = 0;
                    base = fr.base;
                    clo = co;
                    sp = this.sp;
                    break;
                }
            case Op.callBuiltin:
                {
                    int b = code[pc];
                    int argc = code[pc + 1];
                    pc += 2;
                    this.sp = sp;
                    Value r = builtins[b](this, st[sp - argc .. sp]);
                    st = stack;
                    sp -= argc;
                    st[sp++] = r;
                    break;
                }
            case Op.callMethod:
                {
                    int t = code[pc];
                    int m = code[pc + 1];
                    int argc = code[pc + 2];
                    pc += 3;
                    fr.pc = pc;
                    int rb = sp - argc - 1;
                    int ctor = ctorOf(st[rb]);
                    int f = prog.methodTable[t][ctor][m];
                    this.sp = sp;
                    pushFrame(f, rb, rb, null);
                    st = stack;
                    fr = &frames[nframes - 1];
                    fc = prog.funcs[f];
                    code = fc.code;
                    pc = 0;
                    base = rb;
                    clo = null;
                    sp = this.sp;
                    break;
                }
            case Op.ret, Op.retUnit:
                {
                    Value r = code[pc - 1] == cast(int) Op.ret ? st[--sp] : Value.unit;
                    int reset = fr.spReset;
                    nframes--;
                    if (nframes == stopFrames)
                    {
                        this.sp = reset;
                        return r;
                    }
                    sp = reset;
                    st[sp++] = r;
                    fr = &frames[nframes - 1];
                    fc = prog.funcs[fr.fn];
                    code = fc.code;
                    pc = fr.pc;
                    base = fr.base;
                    clo = fr.clo;
                    break;
                }
            case Op.addI:
                st[sp - 2].i = st[sp - 2].i + st[sp - 1].i;
                sp--;
                break;
            case Op.subI:
                st[sp - 2].i = st[sp - 2].i - st[sp - 1].i;
                sp--;
                break;
            case Op.mulI:
                st[sp - 2].i = st[sp - 2].i * st[sp - 1].i;
                sp--;
                break;
            case Op.divI:
                {
                    long b = st[sp - 1].i;
                    if (b == 0)
                        panic("divide by zero");
                    long a = st[sp - 2].i;
                    st[sp - 2].i = b == -1 ? cast(long)(0UL - cast(ulong) a) : a / b;
                    sp--;
                    break;
                }
            case Op.modI:
                {
                    long b = st[sp - 1].i;
                    if (b == 0)
                        panic("modulo by zero");
                    long a = st[sp - 2].i;
                    st[sp - 2].i = b == -1 ? 0 : a % b;
                    sp--;
                    break;
                }
            case Op.negI:
                st[sp - 1].i = cast(long)(0UL - cast(ulong) st[sp - 1].i);
                break;
            case Op.bnot:
                st[sp - 1].i = ~st[sp - 1].i;
                break;
            case Op.band:
                st[sp - 2].i = st[sp - 2].i & st[sp - 1].i;
                sp--;
                break;
            case Op.bor:
                st[sp - 2].i = st[sp - 2].i | st[sp - 1].i;
                sp--;
                break;
            case Op.bxor:
                st[sp - 2].i = st[sp - 2].i ^ st[sp - 1].i;
                sp--;
                break;
            case Op.shl:
                {
                    long b = st[sp - 1].i;
                    if (cast(ulong) b > 63)
                        panic("shift amount out of range");
                    st[sp - 2].i = st[sp - 2].i << cast(int) b;
                    sp--;
                    break;
                }
            case Op.shr:
                {
                    long b = st[sp - 1].i;
                    if (cast(ulong) b > 63)
                        panic("shift amount out of range");
                    st[sp - 2].i = st[sp - 2].i >> cast(int) b;
                    sp--;
                    break;
                }
            case Op.addF:
                st[sp - 2].f = st[sp - 2].f + st[sp - 1].f;
                sp--;
                break;
            case Op.subF:
                st[sp - 2].f = st[sp - 2].f - st[sp - 1].f;
                sp--;
                break;
            case Op.mulF:
                st[sp - 2].f = st[sp - 2].f * st[sp - 1].f;
                sp--;
                break;
            case Op.divF:
                st[sp - 2].f = st[sp - 2].f / st[sp - 1].f;
                sp--;
                break;
            case Op.negF:
                st[sp - 1].f = -st[sp - 1].f;
                break;
            case Op.notB:
                st[sp - 1].i = st[sp - 1].i ^ 1;
                break;
            case Op.eq:
                st[sp - 2] = Value.bool_(valuesEqual(st[sp - 2], st[sp - 1]));
                sp--;
                break;
            case Op.ne:
                st[sp - 2] = Value.bool_(!valuesEqual(st[sp - 2], st[sp - 1]));
                sp--;
                break;
            case Op.lt:
                {
                    auto a = &st[sp - 2];
                    auto b = &st[sp - 1];
                    bool r;
                    switch (a.t)
                    {
                    case VT.float_:
                        r = a.f < b.f;
                        break;
                    case VT.str:
                        r = compareStr(asStr(*a).s, asStr(*b).s) < 0;
                        break;
                    default:
                        r = a.i < b.i;
                        break;
                    }
                    *a = Value.bool_(r);
                    sp--;
                    break;
                }
            case Op.le:
                {
                    auto a = &st[sp - 2];
                    auto b = &st[sp - 1];
                    bool r;
                    switch (a.t)
                    {
                    case VT.float_:
                        r = a.f <= b.f;
                        break;
                    case VT.str:
                        r = compareStr(asStr(*a).s, asStr(*b).s) <= 0;
                        break;
                    default:
                        r = a.i <= b.i;
                        break;
                    }
                    *a = Value.bool_(r);
                    sp--;
                    break;
                }
            case Op.gt:
                {
                    auto a = &st[sp - 2];
                    auto b = &st[sp - 1];
                    bool r;
                    switch (a.t)
                    {
                    case VT.float_:
                        r = a.f > b.f;
                        break;
                    case VT.str:
                        r = compareStr(asStr(*a).s, asStr(*b).s) > 0;
                        break;
                    default:
                        r = a.i > b.i;
                        break;
                    }
                    *a = Value.bool_(r);
                    sp--;
                    break;
                }
            case Op.ge:
                {
                    auto a = &st[sp - 2];
                    auto b = &st[sp - 1];
                    bool r;
                    switch (a.t)
                    {
                    case VT.float_:
                        r = a.f >= b.f;
                        break;
                    case VT.str:
                        r = compareStr(asStr(*a).s, asStr(*b).s) >= 0;
                        break;
                    default:
                        r = a.i >= b.i;
                        break;
                    }
                    *a = Value.bool_(r);
                    sp--;
                    break;
                }
            case Op.concatStr:
                st[sp - 2] = Value.str(asStr(st[sp - 2]).s ~ asStr(st[sp - 1]).s);
                sp--;
                break;
            case Op.concatList:
                {
                    auto a = asList(st[sp - 2]);
                    auto b = asList(st[sp - 1]);
                    auto items = new Value[a.len + b.len];
                    items[0 .. a.len] = a.buf[0 .. a.len];
                    items[a.len .. $] = b.buf[0 .. b.len];
                    st[sp - 2] = Value.obj(VT.list, new ListObj(items));
                    sp--;
                    break;
                }
            case Op.jump:
                pc = code[pc];
                break;
            case Op.jumpIfFalse:
                if (st[--sp].i == 0)
                    pc = code[pc];
                else
                    pc++;
                break;
            case Op.jumpIfTrue:
                if (st[--sp].i != 0)
                    pc = code[pc];
                else
                    pc++;
                break;
            case Op.makeList:
                {
                    int n = code[pc++];
                    Value[] items = st[sp - n .. sp].dup;
                    sp -= n;
                    st[sp++] = Value.obj(VT.list, new ListObj(items));
                    break;
                }
            case Op.makeMap:
                {
                    int n = code[pc++];
                    auto m = new MapObj;
                    int b = sp - 2 * n;
                    foreach (i; 0 .. n)
                        m.set(st[b + 2 * i], st[b + 2 * i + 1]);
                    sp = b;
                    st[sp++] = Value.obj(VT.map, m);
                    break;
                }
            case Op.makeTuple:
                {
                    int n = code[pc++];
                    Value[] items = st[sp - n .. sp].dup;
                    sp -= n;
                    st[sp++] = Value.obj(VT.tuple, new AggObj(-1, 0, items));
                    break;
                }
            case Op.makeStruct:
                {
                    int d = code[pc];
                    int n = code[pc + 1];
                    pc += 2;
                    Value[] items = st[sp - n .. sp].dup;
                    sp -= n;
                    st[sp++] = Value.obj(VT.strukt, new AggObj(d, 0, items));
                    break;
                }
            case Op.makeEnum:
                {
                    int d = code[pc];
                    int v = code[pc + 1];
                    int n = code[pc + 2];
                    pc += 3;
                    if (n == 0)
                        st[sp++] = prog.unitVariants[d][v];
                    else
                    {
                        Value[] items = st[sp - n .. sp].dup;
                        sp -= n;
                        st[sp++] = Value.obj(VT.enum_, new AggObj(d, v, items));
                    }
                    break;
                }
            case Op.getField, Op.getPayload, Op.getTuple:
                st[sp - 1] = asAgg(st[sp - 1]).f[code[pc++]];
                break;
            case Op.indexGet:
                {
                    auto c = &st[sp - 2];
                    long i = st[sp - 1].i;
                    switch (c.t)
                    {
                    case VT.list:
                        {
                            auto l = asList(*c);
                            if (cast(ulong) i >= l.len)
                                panic("index out of bounds");
                            *c = l.buf[i];
                            break;
                        }
                    case VT.str:
                        {
                            auto s = asStr(*c).s;
                            if (cast(ulong) i >= s.length)
                                panic("index out of bounds");
                            *c = Value.char_(s[i]);
                            break;
                        }
                    default:
                        {
                            auto m = asMap(*c);
                            int e = m.find(st[sp - 1]);
                            if (e < 0)
                                panic("missing key");
                            *c = m.vals[e];
                            break;
                        }
                    }
                    sp--;
                    break;
                }
            case Op.indexSet:
                {
                    auto c = st[sp - 3];
                    if (c.t == VT.list)
                    {
                        auto l = asList(c);
                        long i = st[sp - 2].i;
                        if (cast(ulong) i >= l.len)
                            panic("index out of bounds");
                        l.buf[i] = st[sp - 1];
                    }
                    else
                        asMap(c).set(st[sp - 2], st[sp - 1]);
                    sp -= 3;
                    break;
                }
            case Op.noMatch:
                panic("no match");
            case Op.jumpUnlessVariant:
                if (asAgg(st[base + code[pc]]).variant != code[pc + 1])
                    pc = code[pc + 2];
                else
                    pc += 3;
                break;
            case Op.jumpUnlessLen:
                if (asList(st[base + code[pc]]).len != cast(size_t) code[pc + 1])
                    pc = code[pc + 2];
                else
                    pc += 3;
                break;
            case Op.jumpUnlessLenGe:
                if (asList(st[base + code[pc]]).len < cast(size_t) code[pc + 1])
                    pc = code[pc + 2];
                else
                    pc += 3;
                break;
            case Op.pushPayload, Op.pushField, Op.pushTuple:
                st[sp++] = asAgg(st[base + code[pc]]).f[code[pc + 1]];
                pc += 2;
                break;
            case Op.pushElem:
                st[sp++] = asList(st[base + code[pc]]).buf[code[pc + 1]];
                pc += 2;
                break;
            case Op.listRest:
                {
                    auto l = asList(st[base + code[pc]]);
                    size_t from = code[pc + 1];
                    pc += 2;
                    st[sp++] = Value.obj(VT.list, new ListObj(l.buf[from .. l.len].dup));
                    break;
                }
            case Op.seqLen:
                {
                    auto s = st[base + code[pc++]];
                    st[sp++] = Value.int_(s.t == VT.list ? asList(s).len : asStr(s).s.length);
                    break;
                }
            case Op.seqGet:
                {
                    auto s = st[base + code[pc]];
                    long i = st[base + code[pc + 1]].i;
                    pc += 2;
                    st[sp++] = s.t == VT.list ? asList(s).buf[i] : Value.char_(asStr(s).s[i]);
                    break;
                }
            case Op.incLocal:
                st[base + code[pc++]].i++;
                break;
            }
        }
    }
}
