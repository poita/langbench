//! Record decoding (SPEC §1.8).

use crate::error::{Error, Result};
use crate::value::Value;
use crate::varint;

/// A parsed record header over a borrowed payload. Column values are decoded
/// lazily by [`Record::get`], so wide rows can be filtered cheaply.
#[derive(Debug)]
pub struct Record<'a> {
    data: &'a [u8],
    /// `(serial type, body offset)` per column present in the record.
    columns: Vec<(u64, usize)>,
}

/// Number of body bytes occupied by a value of the given serial type.
fn serial_size(serial: u64) -> Result<usize> {
    Ok(match serial {
        0 | 8 | 9 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6 | 7 => 8,
        10 | 11 => return Err(Error::corrupt("reserved serial type")),
        n if n % 2 == 0 => ((n - 12) / 2) as usize,
        n => ((n - 13) / 2) as usize,
    })
}

impl<'a> Record<'a> {
    /// Parse the header of the record stored in `data`.
    pub fn parse(data: &'a [u8]) -> Result<Record<'a>> {
        let (hsize, n) = varint::read(data, 0).ok_or_else(|| Error::corrupt("record header"))?;
        let hsize = usize::try_from(hsize).map_err(|_| Error::corrupt("record header size"))?;
        if hsize > data.len() || hsize < n {
            return Err(Error::corrupt("record header size out of range"));
        }
        let mut pos = n;
        let mut body = hsize;
        let mut columns = Vec::new();
        while pos < hsize {
            let (serial, len) =
                varint::read(data, pos).ok_or_else(|| Error::corrupt("serial type"))?;
            pos += len;
            let serial = serial as u64;
            columns.push((serial, body));
            body = body
                .checked_add(serial_size(serial)?)
                .ok_or_else(|| Error::corrupt("record too large"))?;
        }
        Ok(Record { data, columns })
    }

    /// Number of columns physically present in the record.
    pub fn len(&self) -> usize {
        self.columns.len()
    }

    /// `true` if the record has no columns.
    pub fn is_empty(&self) -> bool {
        self.columns.is_empty()
    }

    /// Decode column `i`. Columns past the end of a short record read as NULL.
    pub fn get(&self, i: usize) -> Result<Value> {
        let Some(&(serial, off)) = self.columns.get(i) else {
            return Ok(Value::Null);
        };
        let size = serial_size(serial)?;
        let bytes = self
            .data
            .get(off..off + size)
            .ok_or_else(|| Error::corrupt("record body truncated"))?;
        Ok(match serial {
            0 => Value::Null,
            1..=6 => {
                let mut v: i64 = if bytes[0] & 0x80 != 0 { -1 } else { 0 };
                for &b in bytes {
                    v = (v << 8) | i64::from(b);
                }
                Value::Integer(v)
            }
            7 => {
                let mut a = [0u8; 8];
                a.copy_from_slice(bytes);
                Value::Real(f64::from_bits(u64::from_be_bytes(a)))
            }
            8 => Value::Integer(0),
            9 => Value::Integer(1),
            n if n % 2 == 0 => Value::Blob(bytes.to_vec()),
            _ => Value::Text(String::from_utf8_lossy(bytes).into_owned()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_each_type() {
        // header: size 9, types: null, int8, int16, real, text(2), blob(1), 0, 1
        let mut rec = vec![9, 0, 1, 2, 7, 13 + 4, 12 + 2, 8, 9];
        rec.push(0xff); // -1
        rec.extend([0xff, 0xfe]); // -2
        rec.extend(1.5f64.to_be_bytes());
        rec.extend(b"hi");
        rec.push(0xaa);
        let r = Record::parse(&rec).unwrap();
        assert_eq!(r.len(), 8);
        assert_eq!(r.get(0).unwrap(), Value::Null);
        assert_eq!(r.get(1).unwrap(), Value::Integer(-1));
        assert_eq!(r.get(2).unwrap(), Value::Integer(-2));
        assert_eq!(r.get(3).unwrap(), Value::Real(1.5));
        assert_eq!(r.get(4).unwrap(), Value::Text("hi".into()));
        assert_eq!(r.get(5).unwrap(), Value::Blob(vec![0xaa]));
        assert_eq!(r.get(6).unwrap(), Value::Integer(0));
        assert_eq!(r.get(7).unwrap(), Value::Integer(1));
        assert_eq!(r.get(8).unwrap(), Value::Null);
    }

    #[test]
    fn six_byte_integer() {
        let rec = [2, 5, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe];
        let r = Record::parse(&rec).unwrap();
        assert_eq!(r.get(0).unwrap(), Value::Integer(-2));
    }

    #[test]
    fn truncated_body_is_an_error() {
        let rec = [2, 6, 1, 2, 3];
        let r = Record::parse(&rec).unwrap();
        assert!(r.get(0).is_err());
    }

    #[test]
    fn reserved_serial_type_is_an_error() {
        assert!(Record::parse(&[2, 10]).is_err());
    }
}
