/**
 * The in-memory value tree shared by the decoder, the text renderer, the text
 * parser and the encoder. All nodes live in an $(REF Arena, protowire,memory).
 */
module protowire.value;

import protowire.memory : Arena, ByteView, Vec;

/// What a $(LREF Slot) currently holds.
enum SlotKind : ubyte
{
    absent, /// Field not present.
    number, /// A singular numeric value (canonical 64-bit form).
    bytes, /// A singular string/bytes value.
    child, /// A singular message value.
    numList, /// A repeated numeric field.
    bytesList, /// A repeated string/bytes field.
    childList, /// A repeated message field.
}

/**
 * One field of a message instance: a tag plus one machine word or slice.
 *
 * Numbers are held as a 64-bit pattern in canonical form: signed types are
 * sign-extended, unsigned types zero-extended, `sint` types un-zigzagged,
 * `bool` is 0 or 1.
 */
struct Slot
{
    SlotKind kind;
    union
    {
        ulong num;
        ByteView view;
        Node* node;
        Vec!ulong* numList;
        Vec!ByteView* bytesList;
        Vec!(Node*)* childList;
    }
}

/// One message instance; `slots[i]` belongs to the schema's `fields[i]`.
struct Node
{
    Slot* slots;
    /// Bit i is set when field i was given (used to reject duplicates).
    ulong seen;
    /// Encoded size in bytes, filled by the encoder's size pass.
    ulong size;
}

/// Allocate an empty node for a message with `fieldCount` fields.
Node* newNode(ref Arena arena, size_t fieldCount) nothrow
{
    auto n = arena.make!Node();
    n.slots = arena.makeArray!Slot(fieldCount);
    return n;
}
