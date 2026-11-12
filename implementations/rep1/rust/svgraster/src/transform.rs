//! Parsing of the SVG `transform` attribute.

use crate::geom::Matrix;
use crate::number::parse_number;

/// Parses a transform list into a single matrix. Unknown functions and
/// functions with too few arguments are skipped; parsing stops at the first
/// malformed construct.
pub fn parse_transform(s: &str) -> Matrix {
    let mut m = Matrix::IDENTITY;
    let mut rest = s;
    loop {
        rest = rest.trim_start_matches(|c: char| c == ',' || c.is_ascii_whitespace());
        let name_len = rest.bytes().take_while(|c| c.is_ascii_alphabetic()).count();
        if name_len == 0 {
            break;
        }
        let name = &rest[..name_len];
        rest = rest[name_len..].trim_start_matches(|c: char| c.is_ascii_whitespace());
        let Some(r) = rest.strip_prefix('(') else { break };
        let Some(close) = r.find(')') else { break };
        let mut args = Vec::new();
        let mut a = &r[..close];
        loop {
            a = a.trim_start_matches(|c: char| c == ',' || c.is_ascii_whitespace());
            match parse_number(a) {
                Some((v, n)) => {
                    args.push(v);
                    a = &a[n..];
                }
                None => break,
            }
        }
        rest = &r[close + 1..];
        if let Some(f) = function_matrix(name, &args) {
            m = m.mul(&f);
        }
    }
    m
}

fn function_matrix(name: &str, a: &[f64]) -> Option<Matrix> {
    match (name, a.len()) {
        ("matrix", n) if n >= 6 => Some(Matrix { a: a[0], b: a[1], c: a[2], d: a[3], e: a[4], f: a[5] }),
        ("translate", 1) => Some(Matrix::translate(a[0], 0.0)),
        ("translate", n) if n >= 2 => Some(Matrix::translate(a[0], a[1])),
        ("scale", 1) => Some(Matrix::scale(a[0], a[0])),
        ("scale", n) if n >= 2 => Some(Matrix::scale(a[0], a[1])),
        ("rotate", 1 | 2) => Some(Matrix::rotate(a[0])),
        ("rotate", n) if n >= 3 => Some(
            Matrix::translate(a[1], a[2])
                .mul(&Matrix::rotate(a[0]))
                .mul(&Matrix::translate(-a[1], -a[2])),
        ),
        ("skewX", n) if n >= 1 => Some(Matrix { c: a[0].to_radians().tan(), ..Matrix::IDENTITY }),
        ("skewY", n) if n >= 1 => Some(Matrix { b: a[0].to_radians().tan(), ..Matrix::IDENTITY }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geom::Point;

    fn close(a: Point, x: f64, y: f64) -> bool {
        (a.x - x).abs() < 1e-9 && (a.y - y).abs() < 1e-9
    }

    #[test]
    fn composes_left_to_right() {
        let m = parse_transform("translate(10, 20) scale(2)");
        assert!(close(m.apply(Point::new(1.0, 1.0)), 12.0, 22.0));
    }

    #[test]
    fn rotate_about_centre() {
        let m = parse_transform("rotate(90 5 5)");
        assert!(close(m.apply(Point::new(10.0, 5.0)), 5.0, 10.0));
    }

    #[test]
    fn skips_unknown_and_short() {
        let m = parse_transform("foo(1) matrix(1 2) translate(3)");
        assert!(close(m.apply(Point::new(0.0, 0.0)), 3.0, 0.0));
    }

    #[test]
    fn skew_and_matrix() {
        let m = parse_transform("skewX(45) matrix(1 0 0 1 1 1)");
        assert!(close(m.apply(Point::new(0.0, 0.0)), 2.0, 1.0));
    }
}
