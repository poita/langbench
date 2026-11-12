/**
 * A from-scratch DEFLATE (RFC 1951) decoder.
 *
 * Import this module to get the whole public API:
 *
 * ---
 * import inflate;
 *
 * ubyte[] raw = decompress(compressedBytes);          // throws InflateException
 * ubyte[] hex = toHex(raw);
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `inflate.decoder` – the decoder entry points `decompress` and `tryDecompress`.)
 *   $(LI `inflate.error` – `InflateException` and the `InflateError` kinds.)
 *   $(LI `inflate.huffman` – canonical Huffman code construction and two-level lookup tables.)
 *   $(LI `inflate.bitreader` – the LSB-first bit reader.)
 *   $(LI `inflate.constants` – RFC 1951 length/distance tables.)
 *   $(LI `inflate.hex` – lowercase hex encoding/decoding helpers.)
 * )
 */
module inflate;

public import inflate.bitreader;
public import inflate.constants;
public import inflate.decoder;
public import inflate.error;
public import inflate.hex;
public import inflate.huffman;
