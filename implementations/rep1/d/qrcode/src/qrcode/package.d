/**
 * A QR Code Model 2 (ISO/IEC 18004) encoder.
 *
 * Import this module for the public API:
 * ---
 * import qrcode;
 *
 * auto code = encode("HELLO WORLD", Ecl.M);   // auto mask
 * writeln(code.toText());
 * ---
 *
 * Modules, by responsibility:
 * $(UL
 *   $(LI `qrcode.tables`    - capacity tables and error correction levels)
 *   $(LI `qrcode.segment`   - mode/version selection and data packing)
 *   $(LI `qrcode.bitbuffer` - MSB-first bit writer)
 *   $(LI `qrcode.gf`        - GF(2^8) and Reed-Solomon)
 *   $(LI `qrcode.matrix`    - function patterns, placement, masking)
 *   $(LI `qrcode.penalty`   - mask penalty scoring)
 *   $(LI `qrcode.encoder`   - the top-level `encode` function and `QrCode`)
 * )
 */
module qrcode;

public import qrcode.encoder;
public import qrcode.tables : Ecl, minVersion, maxVersion;
public import qrcode.segment : Mode, selectMode;
