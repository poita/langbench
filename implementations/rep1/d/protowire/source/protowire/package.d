/**
 * protowire: a schema-driven Protocol Buffers (proto3) wire-format codec with
 * a canonical text form.
 *
 * Import this module to get the whole public API:
 * $(UL
 *   $(LI $(REF Schema, protowire,schema): parse a schema.)
 *   $(LI $(REF Codec, protowire,codec): decode bytes to text and encode text to bytes.)
 *   $(LI $(REF processDocument, protowire,session): the line-oriented request protocol used by the CLI.)
 *   $(LI $(REF ByteBuffer, protowire,memory): the output buffer used by the low-level API.)
 * )
 */
module protowire;

public import protowire.codec;
public import protowire.hex : hexDecode;
public import protowire.memory : ByteBuffer;
public import protowire.schema;
public import protowire.session;
