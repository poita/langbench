//! Secondary-index keys (spec §14.1).

use crate::value::Value;

/// The order-preserving, self-delimiting encoding of an indexable value.
/// Lists and objects have none.
///
/// ```
/// use tessera::{index::vkey, Value};
/// assert_eq!(vkey(&Value::Int(36)).unwrap(), [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0x24]);
/// assert_eq!(vkey(&Value::Str("ada".into())).unwrap(), b"\x40ada\0\0");
/// ```
pub fn vkey(v: &Value) -> Option<Vec<u8>> {
    Some(match v {
        Value::Null => vec![0x10],
        Value::Bool(false) => vec![0x20],
        Value::Bool(true) => vec![0x21],
        Value::Int(n) => {
            let mut k = vec![0x30];
            k.extend_from_slice(&((*n as u64) ^ (1 << 63)).to_be_bytes());
            k
        }
        Value::Str(s) => {
            let mut k = vec![0x40];
            for &b in s.as_bytes() {
                k.push(b);
                if b == 0 {
                    k.push(0xFF);
                }
            }
            k.extend_from_slice(&[0, 0]);
            k
        }
        Value::List(_) | Value::Object(_) => return None,
    })
}

/// The full index key `vkey(value) ‖ document_key` for the value at
/// `segments` of `doc`, or `None` if the document is not indexable there
/// (path missing, or a list or object).
pub fn entry_key(segments: &[String], doc: &Value, doc_key: &[u8]) -> Option<Vec<u8>> {
    let mut k = vkey(doc.get_path(segments)?)?;
    k.extend_from_slice(doc_key);
    Some(k)
}

/// Length of the `vkey` at the start of an index key.
pub fn vkey_len(key: &[u8]) -> usize {
    match key.first() {
        Some(0x10 | 0x20 | 0x21) => 1,
        Some(0x30) => 9,
        Some(0x40) => {
            let mut i = 1;
            while i < key.len() {
                if key[i] == 0 {
                    if key.get(i + 1) == Some(&0xFF) {
                        i += 2;
                        continue;
                    }
                    return (i + 2).min(key.len());
                }
                i += 1;
            }
            key.len()
        }
        _ => key.len(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_examples() {
        assert_eq!(vkey(&Value::Null).unwrap(), [0x10]);
        assert_eq!(vkey(&Value::Bool(true)).unwrap(), [0x21]);
        assert_eq!(vkey(&Value::Int(0)).unwrap(), [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(vkey(&Value::Int(-1)).unwrap(), [0x30, 0x7f, 255, 255, 255, 255, 255, 255, 255]);
        assert_eq!(vkey(&Value::Int(i64::MIN)).unwrap(), [0x30, 0, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(vkey(&Value::Int(i64::MAX)).unwrap(), [0x30, 255, 255, 255, 255, 255, 255, 255, 255]);
        assert_eq!(vkey(&Value::Str(String::new())).unwrap(), [0x40, 0, 0]);
        assert_eq!(vkey(&Value::Str("a\0b".into())).unwrap(), [0x40, 0x61, 0, 0xff, 0x62, 0, 0]);
        assert!(vkey(&Value::List(vec![])).is_none());
    }

    #[test]
    fn document_key_is_recoverable() {
        for v in [Value::Null, Value::Int(5), Value::Str("a\0b".into()), Value::Str(String::new())] {
            let mut k = vkey(&v).unwrap();
            let n = k.len();
            k.extend_from_slice(b"doc\0key");
            assert_eq!(vkey_len(&k), n);
        }
        let segs = vec!["age".to_string()];
        let doc = Value::Object([("age".to_string(), Value::Int(36))].into_iter().collect());
        let k = entry_key(&segs, &doc, b"u1").unwrap();
        assert_eq!(k, [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0x24, b'u', b'1']);
        assert!(entry_key(&["zip".to_string()], &doc, b"u1").is_none());
    }
}
