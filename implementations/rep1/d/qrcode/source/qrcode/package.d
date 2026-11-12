/**
 * QR Code Model 2 encoder (ISO/IEC 18004).
 *
 * Import this module to get the whole public API:
 *
 * ---
 * import qrcode;
 *
 * auto qr = encodeText("HELLO WORLD", Ecl.medium);
 * writeln(qr.toText());
 * ---
 *
 * The library is split by responsibility:
 *
 * $(UL
 *   $(LI `qrcode.tables`   - capacity and error-correction tables)
 *   $(LI `qrcode.bitbuffer` - MSB-first bit accumulator)
 *   $(LI `qrcode.segment`  - mode selection and data bit stream)
 *   $(LI `qrcode.reedsolomon` - GF(2^8) arithmetic and RS codes)
 *   $(LI `qrcode.matrix`   - symbol grid, function patterns, placement, masks)
 *   $(LI `qrcode.penalty`  - mask penalty scoring)
 *   $(LI `qrcode.encoder`  - the top-level `encode` pipeline)
 *   $(LI `qrcode.query`    - parsing of the `<ecl> <mask> <text>` query lines)
 * )
 */
module qrcode;

public import qrcode.tables;
public import qrcode.bitbuffer;
public import qrcode.segment;
public import qrcode.reedsolomon;
public import qrcode.matrix;
public import qrcode.penalty;
public import qrcode.encoder;
public import qrcode.query;
