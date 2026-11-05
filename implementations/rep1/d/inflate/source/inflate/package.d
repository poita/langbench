/**
 * A table-driven DEFLATE (RFC 1951) decoder.
 *
 * Import this package for the whole public API:
 *
 * ---
 * import inflate;
 *
 * ubyte[] raw = decompress(compressedBytes);   // throws InflateException
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `inflate.decoder`   – the decoder itself (`decompress`, `Inflater`).)
 *   $(LI `inflate.errors`    – `InflateError` and `InflateException`.)
 *   $(LI `inflate.hex`       – bulk hexadecimal encoding / decoding helpers.)
 *   $(LI `inflate.huffman`   – canonical Huffman lookup-table construction.)
 *   $(LI `inflate.bitreader` – the LSB-first bit buffer.)
 *   $(LI `inflate.tables`    – constant RFC 1951 tables.)
 * )
 */
module inflate;

public import inflate.decoder;
public import inflate.errors;
public import inflate.hex;
