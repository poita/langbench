//! Matrix Market reading and writing.
//!
//! Reading understands the `coordinate` and `array` formats with the `real`,
//! `integer` and `pattern` fields and the `general`, `symmetric` and
//! `skew-symmetric` symmetries, and always yields a dense [`Matrix`].
//! Writing always produces `array real general` with `%.10e` values.

use crate::matrix::Matrix;
use std::fmt;
use std::fmt::Write as _;

/// A problem found while parsing Matrix Market text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError(pub String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "matrix market parse error: {}", self.0)
    }
}

impl std::error::Error for ParseError {}

fn err<T>(msg: impl Into<String>) -> Result<T, ParseError> {
    Err(ParseError(msg.into()))
}

#[derive(Clone, Copy, PartialEq)]
enum Format {
    Coordinate,
    Array,
}

#[derive(Clone, Copy, PartialEq)]
enum Symmetry {
    General,
    Symmetric,
    Skew,
}

fn parse_usize(tok: Option<&str>, what: &str) -> Result<usize, ParseError> {
    match tok.map(str::parse::<usize>) {
        Some(Ok(v)) => Ok(v),
        _ => err(format!("expected integer for {what}")),
    }
}

fn parse_f64(tok: Option<&str>) -> Result<f64, ParseError> {
    match tok.map(str::parse::<f64>) {
        Some(Ok(v)) => Ok(v),
        _ => err("expected a real value"),
    }
}

/// Parse the text of a Matrix Market file into a dense matrix.
pub fn parse(text: &str) -> Result<Matrix, ParseError> {
    let mut lines = text.lines();
    let banner = lines.next().ok_or_else(|| ParseError("empty file".into()))?;
    let words: Vec<String> = banner.split_whitespace().map(|w| w.to_ascii_lowercase()).collect();
    if words.len() != 5 || words[0] != "%%matrixmarket" || words[1] != "matrix" {
        return err("bad banner");
    }
    let format = match words[2].as_str() {
        "coordinate" => Format::Coordinate,
        "array" => Format::Array,
        other => return err(format!("unsupported format {other}")),
    };
    let pattern = match words[3].as_str() {
        "real" | "integer" => false,
        "pattern" => true,
        other => return err(format!("unsupported field {other}")),
    };
    let sym = match words[4].as_str() {
        "general" => Symmetry::General,
        "symmetric" => Symmetry::Symmetric,
        "skew-symmetric" => Symmetry::Skew,
        other => return err(format!("unsupported symmetry {other}")),
    };

    // Size line: first line that is neither blank nor a comment.
    let size_line = lines
        .by_ref()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with('%'))
        .ok_or_else(|| ParseError("missing size line".into()))?;
    let mut size = size_line.split_whitespace();
    let rows = parse_usize(size.next(), "rows")?;
    let cols = parse_usize(size.next(), "columns")?;
    let mut m = Matrix::zeros(rows, cols);

    // Everything after the size line is whitespace separated data.
    let mut toks = lines.flat_map(str::split_whitespace);

    match format {
        Format::Coordinate => {
            let nnz = parse_usize(size.next(), "nnz")?;
            for _ in 0..nnz {
                let i = parse_usize(toks.next(), "row index")?;
                let j = parse_usize(toks.next(), "column index")?;
                let v = if pattern { 1.0 } else { parse_f64(toks.next())? };
                if i == 0 || j == 0 || i > rows || j > cols {
                    return err("index out of range");
                }
                let (i, j) = (i - 1, j - 1);
                m.set(i, j, v);
                if i != j {
                    match sym {
                        Symmetry::General => {}
                        Symmetry::Symmetric => m.set(j, i, v),
                        Symmetry::Skew => m.set(j, i, -v),
                    }
                }
            }
        }
        Format::Array => match sym {
            Symmetry::General => {
                for j in 0..cols {
                    for i in 0..rows {
                        m.set(i, j, parse_f64(toks.next())?);
                    }
                }
            }
            Symmetry::Symmetric | Symmetry::Skew => {
                if rows != cols {
                    return err("symmetric matrix must be square");
                }
                let skew = sym == Symmetry::Skew;
                for j in 0..cols {
                    for i in (if skew { j + 1 } else { j })..rows {
                        let v = parse_f64(toks.next())?;
                        m.set(i, j, v);
                        if i != j {
                            m.set(j, i, if skew { -v } else { v });
                        }
                    }
                }
            }
        },
    }
    Ok(m)
}

/// Format one value like C's `printf("%.10e")`, printing `-0.0` as `0.0`.
pub fn format_value(v: f64) -> String {
    let v = if v == 0.0 { 0.0 } else { v };
    let s = format!("{v:.10e}");
    let (mantissa, exp) = s.split_once('e').expect("LowerExp output has an exponent");
    let exp: i32 = exp.parse().expect("integer exponent");
    let sign = if exp < 0 { '-' } else { '+' };
    format!("{mantissa}e{sign}{:02}", exp.abs())
}

/// Render a matrix as `array real general` Matrix Market text.
pub fn write(m: &Matrix) -> String {
    let mut out = String::with_capacity(48 + m.rows() * m.cols() * 19);
    out.push_str("%%MatrixMarket matrix array real general\n");
    let _ = writeln!(out, "{} {}", m.rows(), m.cols());
    for j in 0..m.cols() {
        for i in 0..m.rows() {
            out.push_str(&format_value(m.get(i, j)));
            out.push('\n');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn array_general_is_column_major() {
        let m = parse("%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n").unwrap();
        assert_eq!(m, Matrix::from_rows(&[vec![1.0, 2.0], vec![3.0, 4.0]]));
    }

    #[test]
    fn coordinate_general_and_pattern() {
        let m = parse("%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n").unwrap();
        assert_eq!(m, Matrix::from_rows(&[vec![0.5, 0.0], vec![0.0, -1.5]]));
        let p = parse("%%MatrixMarket matrix coordinate pattern general\n2 3 2\n1 3\n2 1\n").unwrap();
        assert_eq!(p, Matrix::from_rows(&[vec![0.0, 0.0, 1.0], vec![1.0, 0.0, 0.0]]));
    }

    #[test]
    fn array_symmetric_and_skew() {
        let s = parse("%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n").unwrap();
        assert_eq!(s, Matrix::from_rows(&[vec![4.0, 2.0], vec![2.0, 5.0]]));
        let k = parse("%%MatrixMarket matrix array real skew-symmetric\n3 3\n1\n2\n3\n").unwrap();
        assert_eq!(
            k,
            Matrix::from_rows(&[vec![0.0, -1.0, -2.0], vec![1.0, 0.0, -3.0], vec![2.0, 3.0, 0.0]])
        );
    }

    #[test]
    fn coordinate_symmetric_and_skew() {
        let s = parse("%%MatrixMarket matrix coordinate integer symmetric\n2 2 2\n1 1 3\n2 1 7\n").unwrap();
        assert_eq!(s, Matrix::from_rows(&[vec![3.0, 7.0], vec![7.0, 0.0]]));
        let k = parse("%%MatrixMarket matrix coordinate real skew-symmetric\n2 2 1\n2 1 7\n").unwrap();
        assert_eq!(k, Matrix::from_rows(&[vec![0.0, -7.0], vec![7.0, 0.0]]));
    }

    #[test]
    fn case_insensitive_banner_comments_and_blank_lines() {
        let text = "%%MATRIXMARKET Matrix ARRAY Real GENERAL\n% hi\n\n  \n1 2\n\n1.0E+03\n  -2.5  \n";
        let m = parse(text).unwrap();
        assert_eq!(m, Matrix::from_rows(&[vec![1000.0, -2.5]]));
    }

    #[test]
    fn formats_like_printf() {
        assert_eq!(format_value(1.0), "1.0000000000e+00");
        assert_eq!(format_value(-0.0), "0.0000000000e+00");
        assert_eq!(format_value(-0.007), "-7.0000000000e-03");
        assert_eq!(format_value(40015.422479), "4.0015422479e+04");
        assert_eq!(format_value(1.5e100), "1.5000000000e+100");
        assert_eq!(format_value(1.2345678901e-300), "1.2345678901e-300");
    }

    #[test]
    fn writes_array_real_general() {
        let m = Matrix::from_rows(&[vec![1.5, 2.0], vec![3.0, 2.5]]);
        assert_eq!(
            write(&m),
            "%%MatrixMarket matrix array real general\n2 2\n1.5000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n2.5000000000e+00\n"
        );
    }

    #[test]
    fn roundtrip() {
        let m = Matrix::from_rows(&[vec![1.0, -2.0], vec![0.25, 8.0]]);
        assert_eq!(parse(&write(&m)).unwrap(), m);
    }
}
