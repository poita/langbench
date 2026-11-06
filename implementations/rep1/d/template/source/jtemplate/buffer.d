/// A growable output buffer used by the renderer.
module jtemplate.buffer;

import core.memory : GC;
import core.stdc.string : memcpy;

/// Append-only character buffer. Appending is amortised O(1) and never
/// copies the buffer's previous contents more than once per doubling.
struct OutBuf
{
    private char[] data_;
    private size_t len_;

    /// Number of bytes written so far.
    @property size_t length() const pure nothrow @safe @nogc { return len_; }

    /// The bytes written so far (valid until the next append).
    const(char)[] opSlice() const pure nothrow @safe @nogc { return data_[0 .. len_]; }

    /// Make room for `extra` more bytes.
    void reserve(size_t extra) nothrow @trusted
    {
        immutable need = len_ + extra;
        if (need <= data_.length)
            return;
        size_t cap = data_.length * 2;
        if (cap < 256) cap = 256;
        if (cap < need) cap = need;
        auto p = cast(char*) GC.malloc(cap, GC.BlkAttr.NO_SCAN);
        if (len_) memcpy(p, data_.ptr, len_);
        data_ = p[0 .. cap];
    }

    /// Append a string.
    void put(const(char)[] s) nothrow @trusted
    {
        if (s.length == 0) return;
        reserve(s.length);
        memcpy(data_.ptr + len_, s.ptr, s.length);
        len_ += s.length;
    }

    /// Append one byte.
    void put(char c) nothrow @trusted
    {
        reserve(1);
        data_.ptr[len_++] = c;
    }

    /// Append the decimal form of an integer.
    void putInt(long v) nothrow @trusted
    {
        char[24] tmp = void;
        size_t i = tmp.length;
        ulong u = v < 0 ? 0UL - cast(ulong) v : cast(ulong) v;
        do
        {
            tmp[--i] = cast(char)('0' + u % 10);
            u /= 10;
        } while (u);
        if (v < 0) tmp[--i] = '-';
        put(tmp[i .. $]);
    }

    /// Discard the contents (keeps the allocation).
    void clear() pure nothrow @safe @nogc { len_ = 0; }

    /// Return the contents as an immutable string. The buffer is left empty.
    string take() nothrow @trusted
    {
        string r;
        if (len_ == 0)
            r = "";
        else if (len_ * 2 < data_.length)
            r = cast(string) data_[0 .. len_].idup;
        else
            r = cast(string) data_[0 .. len_];
        data_ = null;
        len_ = 0;
        return r;
    }
}
