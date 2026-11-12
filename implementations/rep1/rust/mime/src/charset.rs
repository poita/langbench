//! Character-set decoding: ASCII, UTF-8, Latin-1 and windows-1252.

const REPLACEMENT: char = '\u{FFFD}';

/// Code points for bytes 0x80..=0x9F in windows-1252.
const CP1252_HIGH: [u32; 32] = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, //
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

/// Normalises a charset name: strips spaces and tabs, lower-cases ASCII letters.
pub fn normalize_name(name: &str) -> String {
    name.trim_matches(|c| c == ' ' || c == '\t').to_ascii_lowercase()
}

/// The decoders this crate knows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Table {
    Ascii,
    Utf8,
    Latin1,
    Cp1252,
}

fn table_for(name: &str) -> Table {
    match normalize_name(name).as_str() {
        "us-ascii" | "ascii" | "iso-ir-6" | "ansi_x3.4-1968" | "iso646-us" => Table::Ascii,
        "utf-8" | "utf8" | "unicode-1-1-utf-8" => Table::Utf8,
        "iso-8859-1" | "iso8859-1" | "latin-1" | "latin1" | "l1" | "8859-1" | "iso_8859-1" => {
            Table::Latin1
        }
        _ => Table::Cp1252,
    }
}

/// Decodes `bytes` according to the charset called `charset`.
///
/// Unknown (and empty) names fall back to windows-1252. Decoding never fails:
/// undecodable input becomes U+FFFD.
pub fn decode(bytes: &[u8], charset: &str) -> String {
    match table_for(charset) {
        Table::Ascii => bytes
            .iter()
            .map(|&b| if b < 0x80 { b as char } else { REPLACEMENT })
            .collect(),
        Table::Utf8 => decode_utf8(bytes),
        Table::Latin1 => bytes.iter().map(|&b| b as char).collect(),
        Table::Cp1252 => bytes
            .iter()
            .map(|&b| {
                if (0x80..=0x9F).contains(&b) {
                    char::from_u32(CP1252_HIGH[(b - 0x80) as usize]).unwrap_or(REPLACEMENT)
                } else {
                    b as char
                }
            })
            .collect(),
    }
}

/// Decodes UTF-8, replacing each maximal invalid subpart by one U+FFFD.
pub fn decode_utf8(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let b0 = bytes[i];
        if b0 < 0x80 {
            out.push(b0 as char);
            i += 1;
            continue;
        }
        let (len, lo, hi, mask) = match b0 {
            0xC2..=0xDF => (2, 0x80, 0xBF, 0x1F),
            0xE0 => (3, 0xA0, 0xBF, 0x0F),
            0xE1..=0xEC => (3, 0x80, 0xBF, 0x0F),
            0xED => (3, 0x80, 0x9F, 0x0F),
            0xEE..=0xEF => (3, 0x80, 0xBF, 0x0F),
            0xF0 => (4, 0x90, 0xBF, 0x07),
            0xF1..=0xF3 => (4, 0x80, 0xBF, 0x07),
            0xF4 => (4, 0x80, 0x8F, 0x07),
            _ => {
                out.push(REPLACEMENT);
                i += 1;
                continue;
            }
        };
        let mut cp = (b0 & mask) as u32;
        let mut k = 1;
        while k < len {
            let (min, max) = if k == 1 { (lo, hi) } else { (0x80, 0xBF) };
            match bytes.get(i + k) {
                Some(&b) if b >= min && b <= max => {
                    cp = (cp << 6) | (b & 0x3F) as u32;
                    k += 1;
                }
                _ => break,
            }
        }
        if k == len {
            out.push(char::from_u32(cp).unwrap_or(REPLACEMENT));
        } else {
            out.push(REPLACEMENT);
        }
        i += k;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_maximal_subpart() {
        assert_eq!(decode_utf8(b"\xe2\x28\xa1"), "\u{FFFD}(\u{FFFD}");
        assert_eq!(decode_utf8(b"\xf0\x9f"), "\u{FFFD}");
        assert_eq!(decode_utf8(b"\xf0\x9f\x98\x80"), "\u{1F600}");
        assert_eq!(decode_utf8(b"\xed\xa0\x80"), "\u{FFFD}\u{FFFD}\u{FFFD}");
        assert_eq!(decode_utf8(b"\xc0\xaf"), "\u{FFFD}\u{FFFD}");
        assert_eq!(decode_utf8("café".as_bytes()), "café");
    }

    #[test]
    fn tables() {
        assert_eq!(decode(b"caf\xe9", "ISO-8859-1"), "café");
        assert_eq!(decode(b"smart\x92quote", " windows-1252\t"), "smart\u{2019}quote");
        assert_eq!(decode(b"a\xe9", "us-ascii"), "a\u{FFFD}");
        assert_eq!(decode(b"\x81", ""), "\u{81}");
        assert_eq!(decode(b"\x80", "klingon"), "\u{20AC}");
    }
}
