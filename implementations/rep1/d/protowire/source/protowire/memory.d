/**
 * Low-level memory helpers: a growable byte buffer, a per-request bump arena
 * and an arena-backed vector.
 *
 * These exist so that a request can be decoded or encoded without any
 * per-value garbage-collector allocation: the value tree of a request lives in
 * an $(LREF Arena) that is reset (not freed) before the next request.
 */
module protowire.memory;

import core.exception : onOutOfMemoryError;
import core.stdc.stdlib : malloc, realloc, free;
import core.stdc.string : memcpy, memset;

/// A view of immutable-for-our-purposes bytes (string and bytes values).
alias ByteView = const(ubyte)[];

private immutable char[16] hexDigits = "0123456789abcdef";

/**
 * A growable byte buffer backed by `malloc`.
 *
 * It is the output sink used by every renderer in the library. It is not
 * copyable; pass it by `ref`.
 */
struct ByteBuffer
{
    private ubyte* ptr_;
    private size_t len_;
    private size_t cap_;

    @disable this(this);

    ~this() nothrow @nogc @trusted
    {
        free(ptr_);
        ptr_ = null;
        len_ = cap_ = 0;
    }

    /// Number of bytes stored.
    @property size_t length() const pure nothrow @nogc @safe { return len_; }

    /// The stored bytes. Invalidated by any later append.
    @property inout(ubyte)[] data() inout pure nothrow @nogc @trusted
    {
        return ptr_[0 .. len_];
    }

    /// Discard the contents but keep the capacity.
    void clear() pure nothrow @nogc @safe { len_ = 0; }

    /// Cut the buffer back to `newLength` bytes (must not exceed `length`).
    void truncate(size_t newLength) pure nothrow @nogc @safe
    {
        assert(newLength <= len_);
        len_ = newLength;
    }

    /// Make room for at least `extra` more bytes.
    void reserve(size_t extra) nothrow @nogc
    {
        if (extra > cap_ - len_)
            grow(extra);
    }

    /// Pointer to the first unused byte; valid for `reserve`d bytes.
    @property ubyte* tail() pure nothrow @nogc @system { return ptr_ + len_; }

    /// Declare `n` bytes written through $(LREF tail) as part of the contents.
    void advance(size_t n) pure nothrow @nogc @safe
    {
        len_ += n;
    }

    /// Append one byte.
    void putByte(ubyte b) nothrow @nogc @trusted
    {
        if (len_ == cap_)
            grow(1);
        ptr_[len_++] = b;
    }

    /// Append a byte slice.
    void putBytes(const(ubyte)[] s) nothrow @nogc @trusted
    {
        if (s.length == 0)
            return;
        reserve(s.length);
        memcpy(ptr_ + len_, s.ptr, s.length);
        len_ += s.length;
    }

    /// Append the bytes of a string.
    void putString(const(char)[] s) nothrow @nogc @trusted
    {
        putBytes(cast(const(ubyte)[]) s);
    }

    /// Append `v` in decimal.
    void putUnsigned(ulong v) nothrow @nogc @trusted
    {
        char[20] tmp = void;
        size_t i = tmp.length;
        do
        {
            tmp[--i] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v != 0);
        putString(tmp[i .. $]);
    }

    /// Append `v` in decimal with a leading `-` when negative.
    void putSigned(long v) nothrow @nogc
    {
        if (v < 0)
        {
            putByte('-');
            putUnsigned(0UL - cast(ulong) v);
        }
        else
            putUnsigned(cast(ulong) v);
    }

    /// Append the lowercase hexadecimal form of `bytes` (two digits per byte).
    void putHex(const(ubyte)[] bytes) nothrow @nogc @trusted
    {
        reserve(bytes.length * 2);
        ubyte* d = ptr_ + len_;
        foreach (b; bytes)
        {
            *d++ = hexDigits[b >> 4];
            *d++ = hexDigits[b & 15];
        }
        len_ += bytes.length * 2;
    }

    private void grow(size_t extra) nothrow @nogc @trusted
    {
        const need = len_ + extra;
        size_t nc = cap_ < 256 ? 256 : cap_ * 2;
        if (nc < need)
            nc = need;
        auto np = cast(ubyte*) realloc(ptr_, nc);
        if (np is null)
            onOutOfMemoryError();
        ptr_ = np;
        cap_ = nc;
    }
}

/**
 * A bump allocator. Memory is handed out in 16-byte-aligned pieces and is
 * released all at once by $(LREF reset); the underlying chunks are kept for
 * reuse. Memory is not scanned by the garbage collector, so everything stored
 * in an arena may only point into the same arena or into memory that is kept
 * alive elsewhere.
 */
struct Arena
{
    private enum size_t chunkSize = 1 << 20;
    private ubyte*[] chunks;
    private ubyte*[] bigs;
    private size_t used;
    private ubyte* head;
    private size_t off = chunkSize;

    @disable this(this);

    ~this() nothrow @nogc @trusted
    {
        foreach (c; chunks)
            free(c);
        foreach (b; bigs)
            free(b);
    }

    /// Invalidate everything allocated so far and make the memory reusable.
    void reset() nothrow @trusted
    {
        used = 0;
        off = chunkSize;
        head = null;
        foreach (b; bigs)
            free(b);
        bigs.length = 0;
        assumeSafeAppend(bigs);
    }

    /// Allocate `n` uninitialised bytes.
    void* allocRaw(size_t n) nothrow @trusted
    {
        n = (n + 15) & ~cast(size_t) 15;
        if (n > chunkSize / 4)
        {
            auto p = cast(ubyte*) malloc(n);
            if (p is null)
                onOutOfMemoryError();
            bigs ~= p;
            return p;
        }
        if (off + n > chunkSize)
        {
            if (used == chunks.length)
            {
                auto c = cast(ubyte*) malloc(chunkSize);
                if (c is null)
                    onOutOfMemoryError();
                chunks ~= c;
            }
            head = chunks[used++];
            off = 0;
        }
        auto p = head + off;
        off += n;
        return p;
    }

    /// Allocate `n` zero-filled bytes.
    void* allocZeroed(size_t n) nothrow @trusted
    {
        auto p = allocRaw(n);
        memset(p, 0, n);
        return p;
    }

    /// Allocate `n` uninitialised bytes as a mutable slice.
    ubyte[] allocBytes(size_t n) nothrow @trusted
    {
        if (n == 0)
            return null;
        return (cast(ubyte*) allocRaw(n))[0 .. n];
    }

    /// Allocate one zero-initialised `T` (whose all-zero state must be valid).
    T* make(T)() nothrow @trusted
    {
        return cast(T*) allocZeroed(T.sizeof);
    }

    /// Allocate `n` zero-initialised `T`s.
    T* makeArray(T)(size_t n) nothrow @trusted
    {
        return n == 0 ? null : cast(T*) allocZeroed(n * T.sizeof);
    }
}

/// A growable array whose storage lives in an $(LREF Arena).
struct Vec(T)
{
    /// Element storage.
    T* ptr;
    /// Number of elements.
    size_t len;
    /// Capacity in elements.
    size_t cap;
    /// Scratch field for the encoder: cached encoded payload size.
    ulong payload;

    /// Append an element.
    void push(ref Arena a, T v) nothrow @trusted
    {
        if (len == cap)
            grow(a, 1);
        ptr[len++] = v;
    }

    /// Make room for `extra` more elements.
    void reserve(ref Arena a, size_t extra) nothrow
    {
        if (extra > cap - len)
            grow(a, extra);
    }

    /// The elements as a slice.
    @property inout(T)[] items() inout pure nothrow @nogc @trusted
    {
        return ptr[0 .. len];
    }

    private void grow(ref Arena a, size_t extra) nothrow @trusted
    {
        size_t nc = cap ? cap * 2 : 4;
        if (nc < len + extra)
            nc = len + extra;
        auto np = cast(T*) a.allocRaw(nc * T.sizeof);
        if (len)
            memcpy(np, ptr, len * T.sizeof);
        ptr = np;
        cap = nc;
    }
}
