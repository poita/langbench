/++
`IdMap`: an open-addressing hash map from order-id bytes to arena indices.

Keys are borrowed slices (typically views into the input buffer), so lookups
and insertions never allocate per key. Deletion uses backward shifting, so
there are no tombstones.
+/
module orderbook.idmap;

/// Hash map `const(char)[] -> int`. Keys must outlive their entry.
struct IdMap
{
    private struct Slot
    {
        const(char)[] key;
        int value = -1;
    }

    private Slot[] slots;
    private size_t used;
    private size_t mask;

    /// Create a map able to hold about `expected` entries without growing.
    this(size_t expected) @safe pure nothrow
    {
        size_t cap = 16;
        while (cap < expected * 2)
            cap <<= 1;
        slots = new Slot[cap];
        mask = cap - 1;
    }

    /// Number of entries.
    size_t length() const @safe pure nothrow @nogc
    {
        return used;
    }

    private static size_t hash(scope const(char)[] k) @trusted pure nothrow @nogc
    {
        // FNV-1a with a final avalanche step.
        ulong h = 0xcbf29ce484222325UL;
        foreach (c; k)
        {
            h ^= cast(ubyte) c;
            h *= 0x100000001b3UL;
        }
        h ^= h >> 32;
        h *= 0x9E3779B97F4A7C15UL;
        h ^= h >> 29;
        return cast(size_t) h;
    }

    /// Value stored under `key`, or -1 if absent.
    int get(scope const(char)[] key) const @safe pure nothrow @nogc
    {
        if (slots.length == 0)
            return -1;
        size_t i = hash(key) & mask;
        while (slots[i].value >= 0)
        {
            if (slots[i].key == key)
                return slots[i].value;
            i = (i + 1) & mask;
        }
        return -1;
    }

    /// Insert or overwrite `key -> value` (`value` must be >= 0).
    void put(const(char)[] key, int value) @safe pure nothrow
    in (value >= 0)
    {
        if (slots.length == 0 || (used + 1) * 2 > slots.length)
            rehash();
        size_t i = hash(key) & mask;
        while (slots[i].value >= 0)
        {
            if (slots[i].key == key)
            {
                slots[i].value = value;
                return;
            }
            i = (i + 1) & mask;
        }
        slots[i] = Slot(key, value);
        ++used;
    }

    /// Remove `key` if present; returns whether it was.
    bool remove(scope const(char)[] key) @safe pure nothrow @nogc
    {
        if (slots.length == 0)
            return false;
        size_t i = hash(key) & mask;
        while (slots[i].value >= 0)
        {
            if (slots[i].key == key)
            {
                eraseAt(i);
                return true;
            }
            i = (i + 1) & mask;
        }
        return false;
    }

    // Backward-shift deletion of slot `hole`.
    private void eraseAt(size_t hole) @safe pure nothrow @nogc
    {
        size_t j = hole;
        for (;;)
        {
            j = (j + 1) & mask;
            if (slots[j].value < 0)
                break;
            const home = hash(slots[j].key) & mask;
            // Can slot j move into the hole? Only if its home is not in (hole, j].
            const dist = (j - home) & mask;
            const holeDist = (j - hole) & mask;
            if (dist >= holeDist)
            {
                slots[hole] = slots[j];
                hole = j;
            }
        }
        slots[hole] = Slot.init;
        --used;
    }

    private void rehash() @safe pure nothrow
    {
        auto old = slots;
        const cap = old.length == 0 ? 16 : old.length * 2;
        slots = new Slot[cap];
        mask = cap - 1;
        foreach (ref s; old)
        {
            if (s.value < 0)
                continue;
            size_t i = hash(s.key) & mask;
            while (slots[i].value >= 0)
                i = (i + 1) & mask;
            slots[i] = s;
        }
    }
}
