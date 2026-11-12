/// The in-memory value tree produced by decoding and by parsing text.
module protowire.value;

import protowire.schema : FieldDescriptor, FieldKind, MessageDescriptor;

/// The value(s) of one field of one message instance. Which members are used
/// depends on the field's descriptor:
///
/// $(UL
///  $(LI singular numeric/bool: `scalar`)
///  $(LI singular string/bytes: `bytes`)
///  $(LI singular message: `message`)
///  $(LI repeated numeric/bool: `numbers`)
///  $(LI repeated string/bytes: `blobs`)
///  $(LI repeated message: `messages`))
///
/// Numbers are held as 64-bit words: signed kinds (int32, int64, sint32,
/// sint64, sfixed32, sfixed64) are sign-extended, unsigned kinds
/// zero-extended, and bool is 0 or 1.
struct Slot
{
    /// Set once the field has occurred (decode) or been given (text).
    bool present;
    ulong scalar;
    ubyte[] bytes;
    Message message;
    ulong[] numbers;
    ubyte[][] blobs;
    Message[] messages;

    // Encoder scratch: payload length of a packed repeated numeric field.
    package ulong packedSize;
}

/// One message instance: a slot per field of its descriptor (same order as
/// `descriptor.fields`, i.e. by increasing field number).
final class Message
{
    /// The message type.
    const MessageDescriptor descriptor;
    /// Field values, parallel to `descriptor.fields`.
    Slot[] slots;

    // Encoder scratch: encoded size of this message, filled by the size pass.
    package ulong encodedSize;

    this(const MessageDescriptor descriptor) @safe pure nothrow
    {
        this.descriptor = descriptor;
        this.slots = new Slot[descriptor.fields.length];
    }
}
