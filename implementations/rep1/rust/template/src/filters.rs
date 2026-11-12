//! The thirteen built-in filters.

use crate::error::{Error, Result};
use crate::value::{is_ws, Num, Value};
use std::cmp::Ordering;
use std::rc::Rc;

/// A built-in filter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Filter {
    /// `upper`
    Upper,
    /// `lower`
    Lower,
    /// `trim`
    Trim,
    /// `escape`
    Escape,
    /// `replace(old, new)`
    Replace,
    /// `length`
    Length,
    /// `int`
    Int,
    /// `join(sep="")`
    Join,
    /// `first`
    First,
    /// `last`
    Last,
    /// `reverse`
    Reverse,
    /// `sort`
    Sort,
    /// `default(value="")`
    Default,
}

impl Filter {
    /// Resolves a filter by name.
    pub fn from_name(name: &str) -> Option<Filter> {
        Some(match name {
            "upper" => Filter::Upper,
            "lower" => Filter::Lower,
            "trim" => Filter::Trim,
            "escape" => Filter::Escape,
            "replace" => Filter::Replace,
            "length" => Filter::Length,
            "int" => Filter::Int,
            "join" => Filter::Join,
            "first" => Filter::First,
            "last" => Filter::Last,
            "reverse" => Filter::Reverse,
            "sort" => Filter::Sort,
            "default" => Filter::Default,
            _ => return None,
        })
    }

    /// The filter's name.
    pub fn name(self) -> &'static str {
        match self {
            Filter::Upper => "upper",
            Filter::Lower => "lower",
            Filter::Trim => "trim",
            Filter::Escape => "escape",
            Filter::Replace => "replace",
            Filter::Length => "length",
            Filter::Int => "int",
            Filter::Join => "join",
            Filter::First => "first",
            Filter::Last => "last",
            Filter::Reverse => "reverse",
            Filter::Sort => "sort",
            Filter::Default => "default",
        }
    }

    /// Inclusive range of accepted argument counts.
    fn arity(self) -> (usize, usize) {
        match self {
            Filter::Replace => (2, 2),
            Filter::Join | Filter::Default => (0, 1),
            _ => (0, 0),
        }
    }

    /// Applies the filter to an already-evaluated input and arguments.
    ///
    /// Order of checks: an undefined input (except for `default`) is an
    /// `undefined` error, then the argument count is a `type` error.
    pub fn apply(self, input: Value, args: &[Value]) -> Result<Value> {
        if self != Filter::Default {
            input.defined()?;
        }
        let (min, max) = self.arity();
        if args.len() < min || args.len() > max {
            return Err(Error::type_error(format!("wrong number of arguments to {}", self.name())));
        }
        if self != Filter::Default {
            for a in args {
                a.defined()?;
            }
        }
        match self {
            Filter::Default => Ok(if input.is_undefined() {
                args.first().cloned().unwrap_or_else(|| Value::str(""))
            } else {
                input
            }),
            Filter::Upper => Ok(Value::str(input.to_display()?.to_ascii_uppercase())),
            Filter::Lower => Ok(Value::str(input.to_display()?.to_ascii_lowercase())),
            Filter::Trim => Ok(Value::str(input.to_display()?.trim_matches(is_ws))),
            Filter::Escape => Ok(Value::str(escape(&input.to_display()?))),
            Filter::Replace => {
                let s = input.to_display()?;
                let old = args[0].to_display()?;
                let new = args[1].to_display()?;
                Ok(Value::str(if old.is_empty() { s.to_string() } else { s.replace(&*old, &new) }))
            }
            Filter::Length => match &input {
                Value::Str(s) => Ok(Value::Int(s.chars().count() as i64)),
                Value::List(l) => Ok(Value::Int(l.len() as i64)),
                Value::Dict(d) => Ok(Value::Int(d.len() as i64)),
                other => Err(Error::type_error(format!("{} has no length", other.kind_name()))),
            },
            Filter::Int => Ok(Value::Int(to_int(&input))),
            Filter::Join => {
                let seq = input.sequence()?;
                let sep = match args.first() {
                    Some(s) => s.to_display()?,
                    None => Rc::from(""),
                };
                let mut out = String::new();
                for (i, v) in seq.iter().enumerate() {
                    if i > 0 {
                        out.push_str(&sep);
                    }
                    v.write_str(&mut out)?;
                }
                Ok(Value::str(out))
            }
            Filter::First => Ok(input.sequence()?.first().cloned().unwrap_or(Value::Undefined)),
            Filter::Last => Ok(input.sequence()?.last().cloned().unwrap_or(Value::Undefined)),
            Filter::Reverse => {
                if let Value::Str(s) = &input {
                    return Ok(Value::str(s.chars().rev().collect::<String>()));
                }
                let mut v = input.sequence()?.into_vec();
                v.reverse();
                Ok(Value::list(v))
            }
            Filter::Sort => sort(input.sequence()?.into_vec()),
        }
    }
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&#34;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// The `int` filter's conversion; never fails.
fn to_int(v: &Value) -> i64 {
    match v {
        Value::Int(i) => *i,
        Value::Bool(b) => *b as i64,
        Value::Float(f) => *f as i64,
        Value::Str(s) => str_to_int(s.trim_matches(is_ws)),
        _ => 0,
    }
}

fn str_to_int(s: &str) -> i64 {
    let digits = s.strip_prefix(['+', '-']).unwrap_or(s);
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        return match s.parse::<i64>() {
            Ok(i) => i,
            Err(_) => s.parse::<f64>().map(|f| f as i64).unwrap_or(0),
        };
    }
    if is_decimal(digits) {
        return s.parse::<f64>().map(|f| f as i64).unwrap_or(0);
    }
    0
}

/// Matches `([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?` (sign removed).
fn is_decimal(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    let int_start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let int_digits = i - int_start;
    if int_digits > 0 {
        if i < b.len() && b[i] == b'.' {
            i += 1;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
        }
    } else if i < b.len() && b[i] == b'.' {
        i += 1;
        let f = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == f {
            return false;
        }
    } else {
        return false;
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            i += 1;
        }
        let d = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == d {
            return false;
        }
    }
    i == b.len()
}

/// Stable ascending sort: all numbers numerically, all strings by their
/// ASCII-lowercased form; any other mix is a `type` error.
fn sort(items: Vec<Value>) -> Result<Value> {
    if items.iter().all(|v| Num::of(v).is_some()) {
        let mut keyed: Vec<(Num, Value)> = items.into_iter().map(|v| (Num::of(&v).unwrap(), v)).collect();
        keyed.sort_by(|a, b| a.0.num_cmp(b.0).unwrap_or(Ordering::Equal));
        return Ok(Value::list(keyed.into_iter().map(|(_, v)| v).collect()));
    }
    if items.iter().all(|v| matches!(v, Value::Str(_))) {
        let mut keyed: Vec<(String, Value)> = items
            .into_iter()
            .map(|v| match &v {
                Value::Str(s) => (s.to_ascii_lowercase(), v.clone()),
                _ => unreachable!(),
            })
            .collect();
        keyed.sort_by(|a, b| a.0.cmp(&b.0));
        return Ok(Value::list(keyed.into_iter().map(|(_, v)| v).collect()));
    }
    Err(Error::type_error("cannot sort values of mixed or unorderable kinds"))
}
