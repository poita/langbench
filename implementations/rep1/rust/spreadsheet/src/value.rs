//! Cell values and their display forms.

use std::fmt;
use std::rc::Rc;

/// One of the four spreadsheet error codes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ErrorCode {
    /// Division by zero (`#DIV/0!`).
    DivZero,
    /// Invalid cell reference (`#REF!`).
    Ref,
    /// The cell is part of a reference cycle (`#CYCLE!`).
    Cycle,
    /// Wrong type of operand, or a non-finite result (`#VALUE!`).
    Value,
}

impl ErrorCode {
    /// The text shown for this error.
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::DivZero => "#DIV/0!",
            ErrorCode::Ref => "#REF!",
            ErrorCode::Cycle => "#CYCLE!",
            ErrorCode::Value => "#VALUE!",
        }
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The value of a cell (or of an expression during evaluation).
#[derive(Clone, PartialEq, Debug)]
pub enum Value {
    /// No value: an empty cell.
    Empty,
    /// A finite IEEE-754 double.
    Number(f64),
    /// A string.
    Str(Rc<str>),
    /// An error.
    Error(ErrorCode),
}

impl Value {
    /// Convenience constructor for string values.
    pub fn string(s: &str) -> Value {
        Value::Str(Rc::from(s))
    }

    /// True if this is [`Value::Empty`].
    pub fn is_empty(&self) -> bool {
        matches!(self, Value::Empty)
    }
}

impl fmt::Display for Value {
    /// The displayed value: strings verbatim, errors as their code, numbers
    /// per [`format_number`], and empty as the empty string.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Empty => Ok(()),
            Value::Number(n) => f.write_str(&format_number(*n)),
            Value::Str(s) => f.write_str(s),
            Value::Error(e) => f.write_str(e.as_str()),
        }
    }
}

/// Formats a number the way the sheet displays it.
///
/// Zero is `0`; integral values below 1e15 in magnitude are written as plain
/// integers; anything else is formatted like C's `printf("%.10g")`.
///
/// ```
/// use spreadsheet::format_number;
/// assert_eq!(format_number(42.0), "42");
/// assert_eq!(format_number(1.0 / 3.0), "0.3333333333");
/// assert_eq!(format_number(1e20), "1e+20");
/// assert_eq!(format_number(1234567890.5), "1234567890");
/// ```
pub fn format_number(v: f64) -> String {
    if v == 0.0 {
        return "0".to_string();
    }
    if v == v.floor() && v.abs() < 1e15 {
        return format!("{}", v as i64);
    }
    format_g10(v)
}

/// `%.10g` for a finite, nonzero value.
fn format_g10(v: f64) -> String {
    // Rust's `{:e}` with a precision rounds the exact binary value correctly,
    // with ties to even, and reports the exponent after rounding.
    let s = format!("{:.9e}", v.abs());
    let (mantissa, exp) = s.split_once('e').expect("exponent present");
    let exp: i32 = exp.parse().expect("integer exponent");
    let mut digits: Vec<u8> = mantissa.bytes().filter(|b| *b != b'.').collect();
    while digits.len() > 1 && digits.last() == Some(&b'0') {
        digits.pop();
    }
    let mut out = String::new();
    if v < 0.0 {
        out.push('-');
    }
    if !(-4..10).contains(&exp) {
        out.push(digits[0] as char);
        if digits.len() > 1 {
            out.push('.');
            out.extend(digits[1..].iter().map(|&d| d as char));
        }
        out.push('e');
        out.push(if exp < 0 { '-' } else { '+' });
        out.push_str(&format!("{:02}", exp.abs()));
    } else if exp < 0 {
        out.push_str("0.");
        for _ in 0..(-exp - 1) {
            out.push('0');
        }
        out.extend(digits.iter().map(|&d| d as char));
    } else {
        let int_len = exp as usize + 1;
        for i in 0..int_len {
            out.push(digits.get(i).map_or('0', |&d| d as char));
        }
        if digits.len() > int_len {
            out.push('.');
            out.extend(digits[int_len..].iter().map(|&d| d as char));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_examples() {
        let cases: &[(f64, &str)] = &[
            (0.0, "0"),
            (-0.0, "0"),
            (42.0, "42"),
            (-7.0, "-7"),
            (123456789012345.0, "123456789012345"),
            (1e14, "100000000000000"),
            (1e15, "1e+15"),
            (1e20, "1e+20"),
            (-1.5e15, "-1.5e+15"),
            (1.23456789e15, "1.23456789e+15"),
            (1e-5, "1e-05"),
            (2.5e-10, "2.5e-10"),
            (0.5, "0.5"),
            (1234567.891, "1234567.891"),
            (1.0 / 3.0, "0.3333333333"),
            (2.0 / 3.0, "0.6666666667"),
            (0.0001234, "0.0001234"),
            (-2.5, "-2.5"),
            (1234567890.4, "1234567890"),
            (1234567890.5, "1234567890"),
            (2500000000.75, "2500000001"),
            (1200000000.4, "1200000000"),
            (9999999999.7, "1e+10"),
            (1e300, "1e+300"),
            (1.5e-300, "1.5e-300"),
        ];
        for &(v, want) in cases {
            assert_eq!(format_number(v), want, "{v:e}");
        }
    }

    #[test]
    fn value_display() {
        assert_eq!(Value::Empty.to_string(), "");
        assert_eq!(Value::string("hi").to_string(), "hi");
        assert_eq!(Value::Error(ErrorCode::Cycle).to_string(), "#CYCLE!");
        assert_eq!(Value::Number(0.1).to_string(), "0.1");
    }
}
