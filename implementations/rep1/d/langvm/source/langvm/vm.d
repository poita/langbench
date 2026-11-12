/// The virtual machine (SPEC.md sections 14 and 16).
module langvm.vm;

import langvm.builtins : callBuiltin;
import langvm.bytecode;
import langvm.value;

/// A run-time panic: the message is printed as `panic: <message>`.
final class Panic : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// `a ~ b`, reusing spare capacity at the end of `a`'s array when it has any
/// (amortised O(1) appends). Safe because strings only ever grow past their own end.
dstring appendStr(dstring a, dstring b) @trusted
{
    auto r = cast(dchar[]) a;
    r ~= b;
    return cast(dstring) r;
}

/// The maximum number of live call frames (SPEC.md section 14.5).
enum maxFrames = 20000;

/// A saved caller state, pushed on a call.
private struct Frame
{
    Instr[] code;
    size_t pc;
    size_t base;
    ClosureObj clo;
    /// Stack height to restore on return.
    size_t retSp;
    /// Set for frames entered from a built-in: returning leaves the nested `loop`.
    bool native;
}

/// The stack machine.
final class VM
{
    private Program prog;
    private Value[] stk;
    private size_t sp;
    private Frame[] frames;
    private size_t nframes;
    private int depth;
    private char[] outBuf;
    private void delegate(const(char)[]) sink;

    /// Declaration id of the prelude's `Option`, and the shared `None` value.
    int optionDecl;
    Value noneValue;

    /// Create a machine for `prog`; everything the program prints is passed to `sink`.
    this(Program prog, void delegate(const(char)[]) sink)
    {
        this.prog = prog;
        this.sink = sink;
        stk = new Value[1 << 16];
        frames = new Frame[maxFrames + 8];
        optionDecl = prog.optionDecl;
        noneValue = Value.ofObj(Tag.enum_, new AggObj(optionDecl, noneVariant, null));
    }

    // ------------------------------------------------------------ output

    /// Write scalar values as UTF-8 to the output.
    void write(const(dchar)[] s)
    {
        foreach (c; s)
            writeChar(c);
        if (outBuf.length > (1 << 16))
            flush();
    }

    /// Write one scalar value.
    void writeChar(dchar c)
    {
        if (c < 0x80)
            outBuf ~= cast(char) c;
        else if (c < 0x800)
        {
            outBuf ~= cast(char)(0xC0 | (c >> 6));
            outBuf ~= cast(char)(0x80 | (c & 0x3F));
        }
        else if (c < 0x10000)
        {
            outBuf ~= cast(char)(0xE0 | (c >> 12));
            outBuf ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
            outBuf ~= cast(char)(0x80 | (c & 0x3F));
        }
        else
        {
            outBuf ~= cast(char)(0xF0 | (c >> 18));
            outBuf ~= cast(char)(0x80 | ((c >> 12) & 0x3F));
            outBuf ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
            outBuf ~= cast(char)(0x80 | (c & 0x3F));
        }
    }

    /// Hand the pending output to the sink.
    void flush()
    {
        if (outBuf.length)
        {
            sink(outBuf);
            outBuf.length = 0;
            outBuf.assumeSafeAppend();
        }
    }

    // ------------------------------------------------------------ running

    /// Run the program from its entry stub. Throws `Panic` on a run-time error;
    /// the output printed so far is flushed in either case.
    void run()
    {
        scope (exit)
            flush();
        sp = 0;
        nframes = 0;
        depth = 0;
        auto entry = prog.funcs[prog.entry];
        loop(entry.code, 0, 0, null);
    }

    /// Call a closure from a built-in and return its result.
    Value call1(Value f, Value a)
    {
        push(a);
        return callClosure(f, 1);
    }

    /// ditto
    Value call2(Value f, Value a, Value b)
    {
        push(a);
        push(b);
        return callClosure(f, 2);
    }

    private Value callClosure(Value fv, size_t argc)
    {
        auto clo = fv.closure;
        auto f = prog.funcs[clo.fn];
        if (depth >= maxFrames)
            throw new Panic("call stack overflow");
        depth++;
        const base = sp - argc;
        frames[nframes++] = Frame(null, 0, 0, null, base, true);
        enterLocals(f, base);
        return loop(f.code, 0, base, clo);
    }

    private void push(Value v)
    {
        if (sp == stk.length)
            grow();
        stk[sp++] = v;
    }

    private void grow()
    {
        auto n = new Value[stk.length * 2];
        n[0 .. sp] = stk[0 .. sp];
        stk = n;
    }

    /// Reserve the callee's local slots above its arguments.
    private void enterLocals(Func f, size_t base)
    {
        const top = base + f.nlocals;
        while (top + 16 > stk.length)
            grow();
        foreach (i; sp .. top)
            stk[i] = Value.init;
        sp = top;
    }

    private void enter(ref Instr[] code, ref size_t pc, ref size_t base, ref ClosureObj clo, int fn,
        size_t newBase, size_t retSp, ClosureObj newClo)
    {
        if (depth >= maxFrames)
            throw new Panic("call stack overflow");
        depth++;
        frames[nframes++] = Frame(code, pc, base, clo, retSp, false);
        auto f = prog.funcs[fn];
        enterLocals(f, newBase);
        base = newBase;
        code = f.code;
        pc = 0;
        clo = newClo;
    }

    /// The fetch-decode-execute loop. Returns at `halt`, or when a frame entered
    /// from a built-in returns (with that call's result).
    private Value loop(Instr[] code, size_t pc, size_t base, ClosureObj clo)
    {
        for (;;)
        {
            const ins = code[pc++];
            final switch (ins.op)
            {
            case Op.pushConst:
                push(prog.consts[ins.a]);
                break;
            case Op.pushTrue:
                push(Value.ofBool(true));
                break;
            case Op.pushFalse:
                push(Value.ofBool(false));
                break;
            case Op.pushUnit:
                push(Value.init);
                break;
            case Op.loadLocal:
                push(stk[base + ins.a]);
                break;
            case Op.storeLocal:
                stk[base + ins.a] = stk[--sp];
                break;
            case Op.loadUpval:
                push(clo.up[ins.a]);
                break;
            case Op.pop:
                sp--;
                break;
            case Op.dup:
                push(stk[sp - 1]);
                break;
            case Op.makeClosure:
            {
                const n = ins.b;
                auto ups = stk[sp - n .. sp].dup;
                sp -= n;
                push(Value.ofObj(Tag.closure, new ClosureObj(ins.a, ups)));
                break;
            }
            case Op.call:
            {
                const nb = sp - ins.b;
                enter(code, pc, base, clo, ins.a, nb, nb, null);
                break;
            }
            case Op.callValue:
            {
                const nb = sp - ins.a;
                auto c = stk[nb - 1].closure;
                enter(code, pc, base, clo, c.fn, nb, nb - 1, c);
                break;
            }
            case Op.callBuiltin:
            {
                Value[4] tmp = void;
                const n = ins.b;
                tmp[0 .. n] = stk[sp - n .. sp];
                sp -= n;
                push(callBuiltin(this, ins.a, tmp[0 .. n]));
                break;
            }
            case Op.callMethod:
            {
                const nb = sp - ins.c - 1;
                const ctor = ctorOf(stk[nb]);
                const fn = prog.impls[ins.a][ctor][ins.b];
                enter(code, pc, base, clo, fn, nb, nb, null);
                break;
            }
            case Op.ret, Op.retUnit:
            {
                Value r = ins.op == Op.ret ? stk[sp - 1] : Value.init;
                auto fr = &frames[--nframes];
                depth--;
                sp = fr.retSp;
                if (fr.native)
                    return r;
                code = fr.code;
                pc = fr.pc;
                base = fr.base;
                clo = fr.clo;
                push(r);
                break;
            }
            case Op.addI:
                sp--;
                stk[sp - 1].i += stk[sp].i;
                break;
            case Op.subI:
                sp--;
                stk[sp - 1].i -= stk[sp].i;
                break;
            case Op.mulI:
                sp--;
                stk[sp - 1].i *= stk[sp].i;
                break;
            case Op.divI:
            {
                const b = stk[--sp].i;
                if (b == 0)
                    throw new Panic("divide by zero");
                const a = stk[sp - 1].i;
                stk[sp - 1].i = b == -1 ? -a : a / b;
                break;
            }
            case Op.modI:
            {
                const b = stk[--sp].i;
                if (b == 0)
                    throw new Panic("modulo by zero");
                const a = stk[sp - 1].i;
                stk[sp - 1].i = b == -1 ? 0 : a % b;
                break;
            }
            case Op.negI:
                stk[sp - 1].i = -stk[sp - 1].i;
                break;
            case Op.bnot:
                stk[sp - 1].i = ~stk[sp - 1].i;
                break;
            case Op.band:
                sp--;
                stk[sp - 1].i &= stk[sp].i;
                break;
            case Op.bor:
                sp--;
                stk[sp - 1].i |= stk[sp].i;
                break;
            case Op.bxor:
                sp--;
                stk[sp - 1].i ^= stk[sp].i;
                break;
            case Op.shl:
            {
                const b = stk[--sp].i;
                if (b < 0 || b > 63)
                    throw new Panic("shift amount out of range");
                stk[sp - 1].i = stk[sp - 1].i << b;
                break;
            }
            case Op.shr:
            {
                const b = stk[--sp].i;
                if (b < 0 || b > 63)
                    throw new Panic("shift amount out of range");
                stk[sp - 1].i = stk[sp - 1].i >> b;
                break;
            }
            case Op.addF:
                sp--;
                stk[sp - 1].f = stk[sp - 1].f + stk[sp].f;
                break;
            case Op.subF:
                sp--;
                stk[sp - 1].f = stk[sp - 1].f - stk[sp].f;
                break;
            case Op.mulF:
                sp--;
                stk[sp - 1].f = stk[sp - 1].f * stk[sp].f;
                break;
            case Op.divF:
                sp--;
                stk[sp - 1].f = stk[sp - 1].f / stk[sp].f;
                break;
            case Op.negF:
                stk[sp - 1].f = -stk[sp - 1].f;
                break;
            case Op.notB:
                stk[sp - 1].i = !stk[sp - 1].i;
                break;
            case Op.eq:
                sp--;
                stk[sp - 1] = Value.ofBool(valuesEqual(stk[sp - 1], stk[sp]));
                break;
            case Op.ne:
                sp--;
                stk[sp - 1] = Value.ofBool(!valuesEqual(stk[sp - 1], stk[sp]));
                break;
            case Op.lt:
            {
                sp--;
                const a = stk[sp - 1];
                if (a.tag == Tag.int_)
                    stk[sp - 1] = Value.ofBool(a.i < stk[sp].i);
                else
                    stk[sp - 1] = Value.ofBool(compareValues(a, stk[sp]) == -1);
                break;
            }
            case Op.le:
            {
                sp--;
                const r = compareValues(stk[sp - 1], stk[sp]);
                stk[sp - 1] = Value.ofBool(r == -1 || r == 0);
                break;
            }
            case Op.gt:
            {
                sp--;
                const r = compareValues(stk[sp - 1], stk[sp]);
                stk[sp - 1] = Value.ofBool(r == 1);
                break;
            }
            case Op.ge:
            {
                sp--;
                const r = compareValues(stk[sp - 1], stk[sp]);
                stk[sp - 1] = Value.ofBool(r == 1 || r == 0);
                break;
            }
            case Op.concatStr:
                sp--;
                stk[sp - 1] = Value.ofStr(appendStr(stk[sp - 1].str.s, stk[sp].str.s));
                break;
            case Op.concatList:
                sp--;
                stk[sp - 1] = Value.ofList(stk[sp - 1].list.items ~ stk[sp].list.items);
                break;
            case Op.jump:
                pc = ins.a;
                break;
            case Op.jumpIfFalse:
                if (!stk[--sp].i)
                    pc = ins.a;
                break;
            case Op.jumpIfTrue:
                if (stk[--sp].i)
                    pc = ins.a;
                break;
            case Op.makeList:
            {
                const n = ins.a;
                auto items = stk[sp - n .. sp].dup;
                sp -= n;
                push(Value.ofList(items));
                break;
            }
            case Op.makeMap:
            {
                const n = ins.a;
                auto m = new MapObj();
                const first = sp - 2 * n;
                foreach (i; 0 .. n)
                    m.set(stk[first + 2 * i], stk[first + 2 * i + 1]);
                sp = first;
                push(Value.ofObj(Tag.map, m));
                break;
            }
            case Op.makeTuple:
            {
                const n = ins.a;
                auto items = stk[sp - n .. sp].dup;
                sp -= n;
                push(Value.ofObj(Tag.tuple, new AggObj(-1, 0, items)));
                break;
            }
            case Op.makeStruct:
            {
                const n = ins.b;
                auto items = stk[sp - n .. sp].dup;
                sp -= n;
                push(Value.ofObj(Tag.struct_, new AggObj(ins.a, 0, items)));
                break;
            }
            case Op.makeEnum:
            {
                const n = ins.c;
                auto items = stk[sp - n .. sp].dup;
                sp -= n;
                push(Value.ofObj(Tag.enum_, new AggObj(ins.a, ins.b, items)));
                break;
            }
            case Op.getField, Op.getPayload, Op.getTuple:
                stk[sp - 1] = stk[sp - 1].agg.f[ins.a];
                break;
            case Op.indexGet:
            {
                const idx = stk[--sp];
                auto c = stk[sp - 1];
                switch (c.tag)
                {
                case Tag.list:
                {
                    auto l = c.list;
                    if (idx.i < 0 || cast(ulong) idx.i >= l.len)
                        throw new Panic("index out of bounds");
                    stk[sp - 1] = l.buf[cast(size_t) idx.i];
                    break;
                }
                case Tag.str:
                {
                    auto s = c.str.s;
                    if (idx.i < 0 || cast(ulong) idx.i >= s.length)
                        throw new Panic("index out of bounds");
                    stk[sp - 1] = Value.ofChar(s[cast(size_t) idx.i]);
                    break;
                }
                default:
                {
                    auto p = c.map.get(idx);
                    if (p is null)
                        throw new Panic("missing key");
                    stk[sp - 1] = *p;
                    break;
                }
                }
                break;
            }
            case Op.indexSet:
            {
                const v = stk[--sp];
                const idx = stk[--sp];
                auto c = stk[--sp];
                if (c.tag == Tag.list)
                {
                    auto l = c.list;
                    if (idx.i < 0 || cast(ulong) idx.i >= l.len)
                        throw new Panic("index out of bounds");
                    l.buf[cast(size_t) idx.i] = v;
                }
                else
                    c.map.set(idx, v);
                break;
            }
            case Op.isVariant:
                stk[sp - 1] = Value.ofBool(stk[sp - 1].agg.variant == ins.a);
                break;
            case Op.seqLen:
            {
                auto c = stk[sp - 1];
                stk[sp - 1] = Value.ofInt(c.tag == Tag.str ? c.str.s.length : c.list.len);
                break;
            }
            case Op.listRest:
                stk[sp - 1] = Value.ofList(stk[sp - 1].list.items[ins.a .. $].dup);
                break;
            case Op.noMatch:
                throw new Panic("no match");
            case Op.panic:
            {
                import std.conv : to;

                throw new Panic(stk[--sp].str.s.to!string);
            }
            case Op.halt:
                return Value.init;
            }
        }
    }
}
