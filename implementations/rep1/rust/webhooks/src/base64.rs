//! Base64 encoding (standard padded and URL-safe unpadded) and the lenient
//! decoder used for secrets and signatures.

const STANDARD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL_SAFE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn encode_with(data: &[u8], alphabet: &[u8; 64], pad: bool) -> String {
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(alphabet[(n >> 18) as usize & 63] as char);
        out.push(alphabet[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(alphabet[(n >> 6) as usize & 63] as char);
        } else if pad {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(alphabet[n as usize & 63] as char);
        } else if pad {
            out.push('=');
        }
    }
    out
}

/// Standard alphabet, padded with `=` to a multiple of four characters.
///
/// ```
/// assert_eq!(webhooks::base64::encode(b"fo"), "Zm8=");
/// ```
pub fn encode(data: &[u8]) -> String {
    encode_with(data, STANDARD, true)
}

/// URL-safe alphabet, no padding.
///
/// ```
/// assert_eq!(webhooks::base64::encode_url(&[0xfb, 0xff]), "-_8");
/// ```
pub fn encode_url(data: &[u8]) -> String {
    encode_with(data, URL_SAFE, false)
}

/// Decodes Base64 text, returning `None` if it is invalid.
///
/// Both alphabets are accepted (but not mixed), padding is optional but, when
/// present, must be exactly what the encoder would emit, and the unused low
/// bits of the final character are ignored.
///
/// ```
/// use webhooks::base64::decode;
/// assert_eq!(decode(b"QQ==").unwrap(), b"A");
/// assert_eq!(decode(b"QR==").unwrap(), b"A");
/// assert_eq!(decode(b"-_8").unwrap(), vec![0xfb, 0xff]);
/// assert!(decode(b"+-").is_none());
/// ```
pub fn decode(text: &[u8]) -> Option<Vec<u8>> {
    let pad = text.iter().rev().take_while(|&&c| c == b'=').count();
    let body = &text[..text.len() - pad];
    let n = body.len();
    if n % 4 == 1 || pad > 2 {
        return None;
    }
    if pad > 0 && (n + pad) % 4 != 0 {
        return None;
    }
    let (mut has_std, mut has_url) = (false, false);
    let mut out = Vec::with_capacity(n * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &c in body {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => {
                has_std = true;
                62
            }
            b'/' => {
                has_std = true;
                63
            }
            b'-' => {
                has_url = true;
                62
            }
            b'_' => {
                has_url = true;
                63
            }
            _ => return None,
        };
        if has_std && has_url {
            return None;
        }
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_table() {
        let cases: [(&[u8], &str, &str); 5] = [
            (b"", "", ""),
            (b"f", "Zg==", "Zg"),
            (b"fo", "Zm8=", "Zm8"),
            (b"foo", "Zm9v", "Zm9v"),
            (&[0xfb, 0xff], "+/8=", "-_8"),
        ];
        for (data, std, url) in cases {
            assert_eq!(encode(data), std);
            assert_eq!(encode_url(data), url);
        }
    }

    #[test]
    fn decode_valid() {
        assert_eq!(decode(b"").unwrap(), b"");
        assert_eq!(decode(b"Zm9v").unwrap(), b"foo");
        assert_eq!(decode(b"Zm8").unwrap(), b"fo");
        assert_eq!(decode(b"Zm8=").unwrap(), b"fo");
        assert_eq!(decode(b"Zg").unwrap(), b"f");
        assert_eq!(decode(b"QQ==").unwrap(), decode(b"QR==").unwrap());
        assert_eq!(decode(b"+/8=").unwrap(), vec![0xfb, 0xff]);
    }

    #[test]
    fn decode_invalid() {
        for bad in [
            &b"A"[..], b"=", b"==", b"Zg=", b"Zm9v=", b"Zm9v====", b"Zg===", b"Z=g=", b"Zm 9",
            b"Zm9v\n", b"+-8=", b"_/", b"Zm8==", b"Zg==Zg==", b"Z!",
        ] {
            assert!(decode(bad).is_none(), "{:?}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn round_trips() {
        let data: Vec<u8> = (0..=255).collect();
        for len in 0..data.len() {
            assert_eq!(decode(encode(&data[..len]).as_bytes()).unwrap(), &data[..len]);
            assert_eq!(decode(encode_url(&data[..len]).as_bytes()).unwrap(), &data[..len]);
        }
    }
}
