/// The dynamic value type manipulated by templates.
module jtemplate.value;

import jtemplate.ast : MacroNode;
import jtemplate.scopes : Rendering, Scope;

/// Discriminator of a [Value].
enum Kind : ubyte
{
    undefined,   /// the undefined value
    none,        /// `none`
    boolean,     /// `true` / `false`
    integer,     /// 64-bit signed integer
    floating,    /// IEEE double
    str,         /// UTF-8 string
    list,        /// list of values
    dict,        /// insertion-ordered string-keyed dictionary
    macro_,      /// a macro defined by `{% macro %}`
    rangeFn,     /// the built-in `range`
    superFn,     /// the `super` callable bound inside a block body
    loop,        /// the `loop` record bound inside a `for` body
    unset,       /// internal: a macro parameter slot that is not bound yet
}

/// A template macro: its AST, defining scope and rendering.
final class MacroObj
{
    MacroNode node;      ///
    Scope scope_;        /// scope in which the `macro` tag executed
    Rendering rendering; /// rendering that was active at definition
    ///
    this(MacroNode node, Scope scope_, Rendering rendering)
    {
        this.node = node;
        this.scope_ = scope_;
        this.rendering = rendering;
    }
}

/// What `super` is bound to inside a block body.
final class SuperObj
{
    Rendering rendering; ///
    string blockName;    ///
    size_t index;        /// position of the running body in the block's chain
    ///
    this(Rendering rendering, string blockName, size_t index)
    {
        this.rendering = rendering;
        this.blockName = blockName;
        this.index = index;
    }
}

/// Insertion-ordered dictionary with string keys.
///
/// Small dictionaries are searched linearly; larger ones keep a hash index
/// from key to position so a lookup is a single probe.
final class DictObj
{
    private enum linearLimit = 8;

    string[] keys;   /// keys in insertion order
    Value[] vals;    /// values, parallel to `keys`
    private size_t[string] index_;

    /// Number of members.
    @property size_t length() const pure nothrow @safe @nogc { return keys.length; }

    /// Pointer to the value stored under `key`, or null.
    Value* find(const(char)[] key) nothrow @trusted
    {
        if (keys.length <= linearLimit)
        {
            foreach (i, k; keys)
                if (k.length == key.length && k == key)
                    return &vals[i];
            return null;
        }
        if (auto p = key in index_)
            return &vals[*p];
        return null;
    }

    /// Add a member, or replace the value of an existing one.
    void put(string key, Value v)
    {
        if (auto p = find(key))
        {
            *p = v;
            return;
        }
        keys ~= key;
        vals ~= v;
        if (keys.length == linearLimit + 1)
        {
            foreach (i, k; keys)
                index_[k] = i;
        }
        else if (keys.length > linearLimit + 1)
            index_[key] = keys.length - 1;
    }
}

/// A template value. Strings, lists and dictionaries are shared by
/// reference and are never modified once built, so copying a `Value` is O(1).
struct Value
{
    /// Which member of the union is active.
    Kind kind = Kind.undefined;
    /// For `Kind.loop`: the number of iterations of the loop.
    uint aux;

    union
    {
        long i;            /// integer, boolean (0/1), or loop index0
        double d;          /// floating
        string s;          /// str
        Value[] list;      /// list
        DictObj dict;      /// dict
        MacroObj mac;      /// macro
        SuperObj sup;      /// super
    }

    // ---- constructors ----------------------------------------------------

    /// The undefined value.
    static Value undef() pure nothrow @safe @nogc { return Value.init; }

    /// `none`.
    static Value nil() pure nothrow @safe @nogc
    {
        Value v; v.kind = Kind.none; return v;
    }

    /// A boolean.
    static Value fromBool(bool b) pure nothrow @safe @nogc
    {
        Value v; v.kind = Kind.boolean; v.i = b ? 1 : 0; return v;
    }

    /// An integer.
    static Value fromInt(long n) pure nothrow @safe @nogc
    {
        Value v; v.kind = Kind.integer; v.i = n; return v;
    }

    /// A float.
    static Value fromFloat(double x) pure nothrow @safe @nogc
    {
        Value v; v.kind = Kind.floating; v.d = x; return v;
    }

    /// A string.
    static Value fromString(string str) pure nothrow @trusted @nogc
    {
        Value v; v.kind = Kind.str; v.s = str; return v;
    }

    /// A list (the array is shared, not copied).
    static Value fromList(Value[] items) pure nothrow @trusted @nogc
    {
        Value v; v.kind = Kind.list; v.list = items; return v;
    }

    /// A dictionary (shared, not copied).
    static Value fromDict(DictObj obj) pure nothrow @trusted @nogc
    {
        Value v; v.kind = Kind.dict; v.dict = obj; return v;
    }

    /// A loop record for iteration `index0` of `length`.
    static Value fromLoop(size_t index0, size_t length) pure nothrow @trusted @nogc
    {
        Value v; v.kind = Kind.loop; v.i = index0; v.aux = cast(uint) length; return v;
    }

    // ---- queries ---------------------------------------------------------

    /// True for the undefined value.
    @property bool isUndefined() const pure nothrow @safe @nogc { return kind == Kind.undefined; }

    /// True for integers and booleans (booleans are integers in arithmetic).
    @property bool isIntegral() const pure nothrow @safe @nogc
    {
        return kind == Kind.integer || kind == Kind.boolean;
    }

    /// True for integers, floats and booleans.
    @property bool isNumber() const pure nothrow @safe @nogc
    {
        return kind == Kind.integer || kind == Kind.boolean || kind == Kind.floating;
    }

    /// The numeric value as a double (only meaningful for numbers).
    @property double asDouble() const pure nothrow @trusted @nogc
    {
        return kind == Kind.floating ? d : cast(double) i;
    }
}
