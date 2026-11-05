/// The tagged value representation used by the interpreter.
module scheme.value;

import scheme.bignum : BigInt;

/// Discriminates the kinds of `Value`.
enum Tag : ubyte
{
    unbound,  /// sentinel for an unbound global (never a user-visible value)
    fixnum,   /// machine integer, payload `i`
    boolean,  /// payload `i` is 0 or 1
    nil,      /// the empty list
    voidValue,/// the void value
    symbol,   /// payload `i` is the symbol id
    prim,     /// primitive procedure, payload `i` is the primitive id
    pair,     /// payload `p` is a `Pair*`
    str,      /// payload `p` is a `StrObj*`
    big,      /// payload `p` is a `BigInt*` that does not fit a fixnum
    closure,  /// payload `p` is a `Closure` (see `scheme.node`)
}

/// A heap-allocated cons cell.
struct Pair
{
    Value car, cdr;
}

/// A heap-allocated immutable string.
struct StrObj
{
    string s;
}

/// A Scheme value: a tag plus a one-word payload, passed by value. Fixnums,
/// booleans, `()`, void, symbols and primitives never allocate.
struct Value
{
    Tag tag;
    union
    {
        long i;
        void* p;
    }

    /// An integer that fits a machine word.
    static Value fixnum(long v) { Value r; r.tag = Tag.fixnum; r.i = v; return r; }
    /// `#t` or `#f`.
    static Value boolean(bool b) { Value r; r.tag = Tag.boolean; r.i = b; return r; }
    /// A symbol with the given id.
    static Value symbol(int id) { Value r; r.tag = Tag.symbol; r.i = id; return r; }
    /// A primitive procedure with the given id.
    static Value prim(int id) { Value r; r.tag = Tag.prim; r.i = id; return r; }
    /// A string.
    static Value str(string s) { Value r; r.tag = Tag.str; r.p = new StrObj(s); return r; }
    /// A fresh pair.
    static Value cons(Value a, Value d) { Value r; r.tag = Tag.pair; r.p = new Pair(a, d); return r; }
    /// An integer too large for a fixnum.
    static Value bigint(BigInt b) { Value r; r.tag = Tag.big; r.p = new BigInt(b.neg, b.mag); return r; }

    /// The empty list.
    static @property Value nil() { Value r; r.tag = Tag.nil; return r; }
    /// The void value.
    static @property Value voidValue() { Value r; r.tag = Tag.voidValue; return r; }
    /// `#t`.
    static @property Value true_() { return boolean(true); }
    /// `#f`.
    static @property Value false_() { return boolean(false); }

    /// Everything but `#f` is true.
    bool truthy() const { return !(tag == Tag.boolean && i == 0); }
    /// True for fixnums and bignums.
    bool isInteger() const { return tag == Tag.fixnum || tag == Tag.big; }

    /// Payload accessors (no checking).
    Pair* pair() const { return cast(Pair*) p; }
    /// ditto
    StrObj* strObj() const { return cast(StrObj*) p; }
    /// ditto
    BigInt* bigObj() const { return cast(BigInt*) p; }
}

/// Build a proper list from `items`.
Value listFrom(const(Value)[] items, Value tail = Value.nil)
{
    Value r = tail;
    foreach_reverse (v; items)
        r = Value.cons(v, r);
    return r;
}
