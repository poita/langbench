/// Constant tables from RFC 1951.
module inflate.tables;

/// Base match length for length symbols 257..285 (index = symbol - 257).
immutable ushort[29] lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];

/// Number of extra bits for length symbols 257..285.
immutable ubyte[29] lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];

/// Base distance for distance symbols 0..29.
immutable ushort[30] distBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];

/// Number of extra bits for distance symbols 0..29.
immutable ubyte[30] distExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

/// Order in which code-length-code lengths are transmitted.
immutable ubyte[19] codeLengthOrder = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/// Maximum Huffman code length.
enum maxCodeBits = 15;
/// Number of literal/length symbols in the fixed code (286 and 287 are invalid).
enum fixedLitSymbols = 288;
/// Number of distance symbols in the fixed code (30 and 31 are invalid).
enum fixedDistSymbols = 32;
