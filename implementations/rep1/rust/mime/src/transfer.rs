//! Content-Transfer-Encoding decoders (quoted-printable and base64).

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Reads two hexadecimal digits from the start of `bytes`, if present.
pub(crate) fn hex_pair(bytes: &[u8]) -> Option<u8> {
    match bytes {
        [a, b, ..] => Some(hex_val(*a)? * 16 + hex_val(*b)?),
        _ => None,
    }
}

/// Decodes a part body (lines already joined with LF) for the given
/// normalised encoding token.
///
/// Unknown encodings leave the bytes unchanged.
pub fn decode_body(bytes: &[u8], encoding: &str) -> Vec<u8> {
    match encoding {
        "quoted-printable" => decode_quoted_printable(bytes),
        "base64" => decode_base64(bytes),
        _ => bytes.to_vec(),
    }
}

/// Lenient quoted-printable decoding.
pub fn decode_quoted_printable(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b != b'=' {
            out.push(b);
            i += 1;
            continue;
        }
        match bytes.get(i + 1) {
            Some(b'\n') => i += 2,
            _ => {
                if let Some(v) = hex_pair(&bytes[i + 1..]) {
                    out.push(v);
                    i += 3;
                } else if i + 1 == bytes.len() {
                    i += 1;
                } else {
                    out.push(b'=');
                    i += 1;
                }
            }
        }
    }
    out
}

fn b64_val(b: u8) -> Option<u32> {
    match b {
        b'A'..=b'Z' => Some((b - b'A') as u32),
        b'a'..=b'z' => Some((b - b'a') as u32 + 26),
        b'0'..=b'9' => Some((b - b'0') as u32 + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

/// Lenient base64 decoding: everything outside the alphabet (including `=`)
/// is discarded and a dangling final character is dropped.
pub fn decode_base64(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3 + 2);
    let mut acc: u32 = 0;
    let mut n = 0;
    for v in bytes.iter().filter_map(|&b| b64_val(b)) {
        acc = (acc << 6) | v;
        n += 1;
        if n == 4 {
            out.extend_from_slice(&[(acc >> 16) as u8, (acc >> 8) as u8, acc as u8]);
            acc = 0;
            n = 0;
        }
    }
    match n {
        2 => out.push((acc >> 4) as u8),
        3 => out.extend_from_slice(&[(acc >> 10) as u8, (acc >> 2) as u8]),
        _ => {}
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qp_examples() {
        let cases: &[(&[u8], &[u8])] = &[
            (b"a=20b", b"a b"),
            (b"a=\nb", b"ab"),
            (b"a=3Db", b"a=b"),
            (b"a=Zb", b"a=Zb"),
            (b"a=3\n", b"a=3\n"),
            (b"abc=", b"abc"),
            (b"=0D=0A", b"\r\n"),
            (b"x  \ny", b"x  \ny"),
        ];
        for (input, want) in cases {
            assert_eq!(&decode_quoted_printable(input), want, "{:?}", input);
        }
    }

    #[test]
    fn base64_lengths() {
        assert_eq!(decode_base64(b"AAECAw=="), vec![0, 1, 2, 3]);
        assert_eq!(decode_base64(b"QUJD\nREU="), b"ABCDE");
        assert_eq!(decode_base64(b"QUI"), b"AB");
        assert_eq!(decode_base64(b"QUJDR"), b"ABC");
        assert_eq!(decode_base64(b""), b"");
    }

    #[test]
    fn unknown_encoding_is_identity() {
        assert_eq!(decode_body(b"a=20", "x-weird"), b"a=20");
        assert_eq!(decode_body(b"a=20", "7bit"), b"a=20");
    }
}
