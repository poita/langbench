/**
 * The high-level codec: one object per schema that decodes wire bytes to
 * canonical text and encodes canonical text to wire bytes.
 */
module protowire.codec;

import protowire.decoder;
import protowire.encoder;
import protowire.memory;
import protowire.render;
import protowire.schema;
import protowire.textparser;
import protowire.value;

/// Thrown by the convenience methods of $(LREF Codec) on malformed input.
class CodecException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Encodes and decodes messages of one $(REF Schema, protowire,schema).
 *
 * A `Codec` owns scratch memory that is reused between calls, so it is cheap
 * to call repeatedly but is not thread-safe.
 */
final class Codec
{
    private Schema schema_;
    private Arena arena_;
    private string lastError_;

    /// Create a codec for `schema`.
    this(Schema schema) pure nothrow @nogc @safe
    {
        schema_ = schema;
    }

    /// The schema this codec works on.
    @property Schema schema() pure nothrow @nogc @safe
    {
        return schema_;
    }

    /// Description of the most recent failure from the low-level methods.
    @property string lastError() const pure nothrow @nogc @safe
    {
        return lastError_;
    }

    /**
     * Decode `wire` as message `msgIndex` and append its canonical text to
     * `text`. On failure returns false and leaves `text` unchanged.
     */
    bool decodeToText(size_t msgIndex, const(ubyte)[] wire, ref ByteBuffer text) nothrow
    {
        arena_.reset();
        auto dec = Decoder(wire, schema_.messages, &arena_);
        Node* root = newNode(arena_, schema_.messages[msgIndex].fields.length);
        if (!dec.decodeMessage(msgIndex, root, 0, wire.length, 0))
        {
            lastError_ = dec.error;
            return false;
        }
        renderMessage(text, schema_.messages, msgIndex, root);
        return true;
    }

    /**
     * Parse `text` as message `msgIndex` and append its wire encoding to
     * `wire`. On failure returns false and leaves `wire` unchanged.
     */
    bool encodeFromText(size_t msgIndex, const(ubyte)[] text, ref ByteBuffer wire) nothrow
    {
        arena_.reset();
        auto parser = TextParser(text, schema_.messages, &arena_);
        Node* root = newNode(arena_, schema_.messages[msgIndex].fields.length);
        if (!parser.parseDocument(msgIndex, root))
        {
            lastError_ = parser.error;
            return false;
        }
        encodeNode(schema_.messages, msgIndex, root, wire);
        return true;
    }

    /**
     * Decode `wire` as message `message` and return its canonical text.
     *
     * Throws: $(LREF CodecException) if the message is unknown or `wire` is malformed.
     */
    string decode(string message, const(ubyte)[] wire) @trusted
    {
        ByteBuffer buf;
        if (!decodeToText(lookup(message), wire, buf))
            throw new CodecException(lastError_);
        return cast(string) buf.data.idup;
    }

    /**
     * Encode canonical `text` as message `message` and return the bytes.
     *
     * Throws: $(LREF CodecException) if the message is unknown or `text` is malformed.
     */
    ubyte[] encode(string message, string text) @trusted
    {
        ByteBuffer buf;
        if (!encodeFromText(lookup(message), cast(const(ubyte)[]) text, buf))
            throw new CodecException(lastError_);
        return buf.data.dup;
    }

    private size_t lookup(string message)
    {
        const i = schema_.messageIndex(message);
        if (i < 0)
            throw new CodecException("unknown message: " ~ message);
        return i;
    }
}
