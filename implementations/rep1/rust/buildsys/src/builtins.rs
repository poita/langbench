//! The 39 built-in functions of KBL.
//!
//! A call is performed by the evaluator in a fixed order: look the name up
//! with [`lookup`], evaluate the arguments, check the arity and the argument
//! types with [`check_args`], then run [`call`].

use crate::error::{Error, ErrorKind, Result};
use crate::glob::Pattern;
use crate::value::Value;
use crate::workspace::Workspace;
use std::collections::HashSet;
use std::rc::Rc;

/// The type an argument position accepts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ty {
    Str,
    Int,
    Bool,
    List,
    Any,
    StrOrList,
    StrOrInt,
    StrIntBool,
}

impl Ty {
    /// The token used in `E_TYPE` messages.
    pub fn token(self) -> &'static str {
        match self {
            Ty::Str => "str",
            Ty::Int => "int",
            Ty::Bool => "bool",
            Ty::List => "list",
            Ty::Any => "any",
            Ty::StrOrList => "str|list",
            Ty::StrOrInt => "str|int",
            Ty::StrIntBool => "str|int|bool",
        }
    }

    /// Whether the value is accepted.
    pub fn accepts(self, v: &Value) -> bool {
        matches!(
            (self, v),
            (Ty::Any, _)
                | (Ty::Str, Value::Str(_))
                | (Ty::Int, Value::Int(_))
                | (Ty::Bool, Value::Bool(_))
                | (Ty::List, Value::List(_))
                | (Ty::StrOrList, Value::Str(_) | Value::List(_))
                | (Ty::StrOrInt, Value::Str(_) | Value::Int(_))
                | (Ty::StrIntBool, Value::Str(_) | Value::Int(_) | Value::Bool(_))
        )
    }
}

/// A function's name, arity range and argument types (the last type repeats
/// for variadic positions).
pub struct FnSpec {
    pub name: &'static str,
    pub min: usize,
    pub max: usize,
    pub types: &'static [Ty],
}

macro_rules! f {
    ($name:expr, $min:expr, $max:expr, [$($t:ident),*]) => {
        FnSpec { name: $name, min: $min, max: $max, types: &[$(Ty::$t),*] }
    };
}

static SPECS: [FnSpec; 39] = [
    f!("len", 1, 1, [StrOrList]),
    f!("count", 1, 1, [List]),
    f!("upper", 1, 1, [Str]),
    f!("lower", 1, 1, [Str]),
    f!("trim", 1, 1, [Str]),
    f!("replace", 3, 3, [Str, Str, Str]),
    f!("starts_with", 2, 2, [Str, Str]),
    f!("ends_with", 2, 2, [Str, Str]),
    f!("contains", 2, 2, [Str, Str]),
    f!("substr", 3, 3, [Str, Int, Int]),
    f!("split", 2, 2, [Str, Str]),
    f!("join", 2, 2, [List, Str]),
    f!("str", 1, 1, [StrIntBool]),
    f!("int", 1, 1, [StrOrInt]),
    f!("dirname", 1, 1, [Str]),
    f!("basename", 1, 1, [Str]),
    f!("stem", 1, 1, [Str]),
    f!("ext", 1, 1, [Str]),
    f!("pathjoin", 1, 8, [Str]),
    f!("map", 2, 2, [List, Str]),
    f!("filter", 2, 2, [List, Str]),
    f!("reject", 2, 2, [List, Str]),
    f!("sort", 1, 1, [List]),
    f!("uniq", 1, 1, [List]),
    f!("reverse", 1, 1, [List]),
    f!("first", 1, 1, [List]),
    f!("last", 1, 1, [List]),
    f!("slice", 3, 3, [List, Int, Int]),
    f!("has", 2, 2, [List, Any]),
    f!("indexof", 2, 2, [List, Any]),
    f!("range", 1, 1, [Int]),
    f!("sum", 1, 1, [List]),
    f!("flatten", 1, 1, [List]),
    f!("zip", 2, 2, [List, List]),
    f!("is_str", 1, 1, [Any]),
    f!("is_int", 1, 1, [Any]),
    f!("is_bool", 1, 1, [Any]),
    f!("is_list", 1, 1, [Any]),
    f!("glob", 1, 1, [Str]),
];

/// Finds a built-in function by name.
pub fn lookup(name: &str) -> Option<&'static FnSpec> {
    SPECS.iter().find(|s| s.name == name)
}

/// Checks the argument count, then the argument types in ascending order.
pub fn check_args(spec: &FnSpec, args: &[Value]) -> Result<()> {
    let n = args.len();
    if n < spec.min || n > spec.max {
        let expected = if spec.min == spec.max { spec.min.to_string() } else { format!("{}-{}", spec.min, spec.max) };
        return Err(Error::new(ErrorKind::Arity, format!("fn {}: expected {expected}, got {n}", spec.name)));
    }
    for (i, a) in args.iter().enumerate() {
        let ty = spec.types[i.min(spec.types.len() - 1)];
        if !ty.accepts(a) {
            return Err(Error::type_error(&format!("fn {} argument {}", spec.name, i + 1), ty.token(), a.type_name()));
        }
    }
    Ok(())
}

fn bytes(v: &Value) -> &[u8] {
    match v {
        Value::Str(s) => s.as_slice(),
        _ => unreachable!("argument types are checked before the call"),
    }
}

fn int(v: &Value) -> i64 {
    match v {
        Value::Int(n) => *n,
        _ => unreachable!("argument types are checked before the call"),
    }
}

fn list(v: &Value) -> &Rc<Vec<Value>> {
    match v {
        Value::List(l) => l,
        _ => unreachable!("argument types are checked before the call"),
    }
}

fn strv(b: Vec<u8>) -> Value {
    Value::str(b)
}

/// Decimal text of an integer, as interpolation produces.
pub fn int_text(n: i64) -> String {
    n.to_string()
}

/// Finds the first occurrence of `needle` in `hay` at or after `from`.
pub fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() {
        return Some(from.min(hay.len()));
    }
    if needle.len() > hay.len() {
        return None;
    }
    let first = needle[0];
    let last_start = hay.len() - needle.len();
    let mut i = from;
    while i <= last_start {
        match hay[i..=last_start].iter().position(|&b| b == first) {
            None => return None,
            Some(off) => {
                i += off;
                if &hay[i..i + needle.len()] == needle {
                    return Some(i);
                }
                i += 1;
            }
        }
    }
    None
}

/// The `replace` scan shared by the function and the command: every
/// non-overlapping occurrence of `from` (non-empty) becomes `to`.
pub fn replace_all(s: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while let Some(p) = find(s, from, i) {
        out.extend_from_slice(&s[i..p]);
        out.extend_from_slice(to);
        i = p + from.len();
    }
    out.extend_from_slice(&s[i..]);
    out
}

fn clamp_range(n: usize, start: i64, count: i64) -> (usize, usize) {
    let n_i = n as i128;
    let mut s = i128::from(start);
    if s < 0 {
        s += n_i;
    }
    let s = s.clamp(0, n_i);
    let c = i128::from(count).clamp(0, n_i - s);
    (s as usize, c as usize)
}

fn path_stem_ext(p: &[u8]) -> (&[u8], &[u8]) {
    let base = basename(p);
    match base.iter().rposition(|&b| b == b'.') {
        Some(i) if i > 0 => (&base[..i], &base[i..]),
        _ => (base, &[]),
    }
}

fn basename(p: &[u8]) -> &[u8] {
    match p.iter().rposition(|&b| b == b'/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

fn parse_int(s: &[u8]) -> Option<i64> {
    let (neg, digits) = match s.split_first() {
        Some((b'-', rest)) => (true, rest),
        _ => (false, s),
    };
    if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let mut acc: u128 = 0;
    for &d in digits {
        acc = (acc * 10 + u128::from(d - b'0')).min(1 << 64);
    }
    if neg {
        if acc <= 1 << 63 {
            Some((acc as i128).wrapping_neg() as i64)
        } else {
            None
        }
    } else if acc < 1 << 63 {
        Some(acc as i64)
    } else {
        None
    }
}

fn bad_pattern(name: &str) -> Error {
    Error::arg("fn", name, "bad pattern")
}

/// Runs a built-in function whose arguments have passed [`check_args`].
pub fn call(name: &str, args: &[Value], ws: &Workspace) -> Result<Value> {
    let a = args;
    Ok(match name {
        "len" => match &a[0] {
            Value::Str(s) => Value::Int(s.len() as i64),
            v => Value::Int(list(v).len() as i64),
        },
        "count" => Value::Int(list(&a[0]).len() as i64),
        "upper" => strv(bytes(&a[0]).to_ascii_uppercase()),
        "lower" => strv(bytes(&a[0]).to_ascii_lowercase()),
        "trim" => {
            let s = bytes(&a[0]);
            let is_ws = |b: &u8| matches!(*b, b' ' | b'\t' | b'\n' | b'\r');
            let start = s.iter().position(|b| !is_ws(b)).unwrap_or(s.len());
            let end = s.iter().rposition(|b| !is_ws(b)).map_or(start, |i| i + 1);
            strv(s[start..end].to_vec())
        }
        "replace" => {
            let from = bytes(&a[1]);
            if from.is_empty() {
                return Err(Error::arg("fn", "replace", "empty pattern"));
            }
            strv(replace_all(bytes(&a[0]), from, bytes(&a[2])))
        }
        "starts_with" => Value::Bool(bytes(&a[0]).starts_with(bytes(&a[1]))),
        "ends_with" => Value::Bool(bytes(&a[0]).ends_with(bytes(&a[1]))),
        "contains" => Value::Bool(find(bytes(&a[0]), bytes(&a[1]), 0).is_some()),
        "substr" => {
            let s = bytes(&a[0]);
            let (st, c) = clamp_range(s.len(), int(&a[1]), int(&a[2]));
            strv(s[st..st + c].to_vec())
        }
        "split" => {
            let (s, sep) = (bytes(&a[0]), bytes(&a[1]));
            if sep.is_empty() {
                return Err(Error::arg("fn", "split", "empty separator"));
            }
            let mut pieces = Vec::new();
            let mut i = 0;
            while let Some(p) = find(s, sep, i) {
                pieces.push(strv(s[i..p].to_vec()));
                i = p + sep.len();
            }
            pieces.push(strv(s[i..].to_vec()));
            Value::list(pieces)
        }
        "join" => {
            let sep = bytes(&a[1]);
            let mut out = Vec::new();
            for (i, v) in list(&a[0]).iter().enumerate() {
                if i > 0 {
                    out.extend_from_slice(sep);
                }
                match v {
                    Value::Str(s) => out.extend_from_slice(s),
                    Value::Int(n) => out.extend_from_slice(int_text(*n).as_bytes()),
                    other => {
                        return Err(Error::type_error(&format!("fn join element {i}"), "str|int", other.type_name()));
                    }
                }
            }
            strv(out)
        }
        "str" => match &a[0] {
            Value::Str(s) => Value::Str(s.clone()),
            Value::Int(n) => strv(int_text(*n).into_bytes()),
            Value::Bool(b) => strv(b.to_string().into_bytes()),
            Value::List(_) => unreachable!("checked"),
        },
        "int" => match &a[0] {
            Value::Int(n) => Value::Int(*n),
            Value::Str(s) => match parse_int(s) {
                Some(n) => Value::Int(n),
                None => return Err(Error::arg("fn", "int", "bad integer")),
            },
            _ => unreachable!("checked"),
        },
        "dirname" => {
            let s = bytes(&a[0]);
            strv(match s.iter().rposition(|&b| b == b'/') {
                Some(i) => s[..i].to_vec(),
                None => Vec::new(),
            })
        }
        "basename" => strv(basename(bytes(&a[0])).to_vec()),
        "stem" => strv(path_stem_ext(bytes(&a[0])).0.to_vec()),
        "ext" => strv(path_stem_ext(bytes(&a[0])).1.to_vec()),
        "pathjoin" => {
            let parts: Vec<&[u8]> = a.iter().map(bytes).filter(|p| !p.is_empty()).collect();
            strv(parts.join(&b'/'))
        }
        "map" => {
            let pat = bytes(&a[1]);
            let mut out = Vec::new();
            for (i, v) in list(&a[0]).iter().enumerate() {
                let Value::Str(elem) = v else {
                    return Err(Error::type_error(&format!("fn map element {i}"), "str", v.type_name()));
                };
                let mut s = Vec::with_capacity(pat.len() + elem.len());
                let mut j = 0;
                while j < pat.len() {
                    if pat[j] == b'%' {
                        if pat.get(j + 1) == Some(&b'%') {
                            s.push(b'%');
                            j += 2;
                        } else {
                            s.extend_from_slice(elem);
                            j += 1;
                        }
                    } else {
                        s.push(pat[j]);
                        j += 1;
                    }
                }
                out.push(strv(s));
            }
            Value::list(out)
        }
        "filter" | "reject" => {
            let pat = Pattern::compile(bytes(&a[1])).ok_or_else(|| bad_pattern(name))?;
            let keep_matching = name == "filter";
            let mut out = Vec::new();
            for (i, v) in list(&a[0]).iter().enumerate() {
                let Value::Str(elem) = v else {
                    return Err(Error::type_error(&format!("fn {name} element {i}"), "str", v.type_name()));
                };
                if pat.matches(elem) == keep_matching {
                    out.push(v.clone());
                }
            }
            Value::list(out)
        }
        "sort" => {
            let mut v: Vec<Value> = list(&a[0]).as_ref().clone();
            v.sort();
            Value::list(v)
        }
        "uniq" => {
            let mut seen = HashSet::new();
            let out: Vec<Value> = list(&a[0]).iter().filter(|v| seen.insert((*v).clone())).cloned().collect();
            Value::list(out)
        }
        "reverse" => Value::list(list(&a[0]).iter().rev().cloned().collect()),
        "first" => list(&a[0]).first().cloned().ok_or_else(|| Error::arg("fn", "first", "empty list"))?,
        "last" => list(&a[0]).last().cloned().ok_or_else(|| Error::arg("fn", "last", "empty list"))?,
        "slice" => {
            let l = list(&a[0]);
            let (st, c) = clamp_range(l.len(), int(&a[1]), int(&a[2]));
            Value::list(l[st..st + c].to_vec())
        }
        "has" => Value::Bool(list(&a[0]).iter().any(|v| *v == a[1])),
        "indexof" => Value::Int(list(&a[0]).iter().position(|v| *v == a[1]).map_or(-1, |i| i as i64)),
        "range" => {
            let n = int(&a[0]);
            if n < 0 {
                return Err(Error::arg("fn", "range", "negative"));
            }
            Value::list((0..n).map(Value::Int).collect())
        }
        "sum" => {
            let mut total: i64 = 0;
            for (i, v) in list(&a[0]).iter().enumerate() {
                match v {
                    Value::Int(n) => total = total.wrapping_add(*n),
                    other => return Err(Error::type_error(&format!("fn sum element {i}"), "int", other.type_name())),
                }
            }
            Value::Int(total)
        }
        "flatten" => {
            let mut out = Vec::new();
            for v in list(&a[0]).iter() {
                match v {
                    Value::List(inner) => out.extend(inner.iter().cloned()),
                    other => out.push(other.clone()),
                }
            }
            Value::list(out)
        }
        "zip" => {
            let (x, y) = (list(&a[0]), list(&a[1]));
            Value::list(x.iter().zip(y.iter()).map(|(p, q)| Value::list(vec![p.clone(), q.clone()])).collect())
        }
        "is_str" => Value::Bool(matches!(a[0], Value::Str(_))),
        "is_int" => Value::Bool(matches!(a[0], Value::Int(_))),
        "is_bool" => Value::Bool(matches!(a[0], Value::Bool(_))),
        "is_list" => Value::Bool(matches!(a[0], Value::List(_))),
        "glob" => {
            let pat = Pattern::compile(bytes(&a[0])).ok_or_else(|| bad_pattern("glob"))?;
            Value::list(ws.glob(&pat).into_iter().map(Value::str).collect())
        }
        other => unreachable!("unknown builtin {other}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(name: &str, args: Vec<Value>) -> Result<Value> {
        let spec = lookup(name).expect("known");
        check_args(spec, &args)?;
        call(name, &args, &Workspace::new())
    }

    fn s(x: &str) -> Value {
        Value::str(x)
    }

    #[test]
    fn there_are_39_functions() {
        assert_eq!(SPECS.len(), 39);
    }

    #[test]
    fn substr_clamping() {
        let r = |a, b, c| run("substr", vec![s(a), Value::Int(b), Value::Int(c)]).unwrap();
        assert_eq!(r("abcdef", 1, 3), s("bcd"));
        assert_eq!(r("abcdef", -2, 5), s("ef"));
        assert_eq!(r("abcdef", 10, 2), s(""));
        assert_eq!(r("abcdef", 2, -1), s(""));
        assert_eq!(r("abcdef", -10, 2), s("ab"));
    }

    #[test]
    fn split_and_join() {
        let v = run("split", vec![s("a,,b"), s(",")]).unwrap();
        assert_eq!(v, Value::list(vec![s("a"), s(""), s("b")]));
        assert_eq!(run("split", vec![s(""), s(",")]).unwrap(), Value::list(vec![s("")]));
        assert_eq!(run("join", vec![Value::list(vec![s("a"), Value::Int(2)]), s("-")]).unwrap(), s("a-2"));
        let e = run("join", vec![Value::list(vec![s("a"), Value::Bool(true)]), s("-")]).unwrap_err();
        assert_eq!(e.render(), b"E_TYPE fn join element 1: expected str|int, got bool");
    }

    #[test]
    fn replace_scan() {
        assert_eq!(run("replace", vec![s("aaa"), s("aa"), s("b")]).unwrap(), s("ba"));
        let e = run("replace", vec![s("a"), s(""), s("b")]).unwrap_err();
        assert_eq!(e.render(), b"E_ARG fn replace: empty pattern");
    }

    #[test]
    fn int_parsing() {
        assert_eq!(run("int", vec![s("-0012")]).unwrap(), Value::Int(-12));
        assert_eq!(run("int", vec![s("9223372036854775807")]).unwrap(), Value::Int(i64::MAX));
        assert_eq!(run("int", vec![s("-9223372036854775808")]).unwrap(), Value::Int(i64::MIN));
        for bad in ["9223372036854775808", "", "-", "+1", " 1", "1 ", "1.5"] {
            assert!(run("int", vec![s(bad)]).is_err(), "{bad}");
        }
    }

    #[test]
    fn path_functions() {
        let one = |f: &str, x: &str| run(f, vec![s(x)]).unwrap();
        assert_eq!(one("stem", "src/a.b.txt"), s("a.b"));
        assert_eq!(one("ext", "src/a.b.txt"), s(".txt"));
        assert_eq!(one("stem", "src/.hidden"), s(".hidden"));
        assert_eq!(one("ext", "src/.hidden"), s(""));
        assert_eq!(one("ext", "src/x."), s("."));
        assert_eq!(one("dirname", "a/b/c"), s("a/b"));
        assert_eq!(one("dirname", "c"), s(""));
        assert_eq!(one("basename", "a/b/c"), s("c"));
        assert_eq!(run("pathjoin", vec![s("out"), s(""), s("a.txt")]).unwrap(), s("out/a.txt"));
        assert_eq!(run("pathjoin", vec![s("out/")]).unwrap(), s("out/"));
    }

    #[test]
    fn map_pattern() {
        let l = Value::list(vec![s("a"), s("b")]);
        assert_eq!(run("map", vec![l, s("out/%.o")]).unwrap(), Value::list(vec![s("out/a.o"), s("out/b.o")]));
        assert_eq!(run("map", vec![Value::list(vec![s("a")]), s("100%%-%")]).unwrap(), Value::list(vec![s("100%-a")]));
    }

    #[test]
    fn filter_compiles_pattern_first() {
        let e = run("filter", vec![Value::list(vec![Value::Int(1)]), s("")]).unwrap_err();
        assert_eq!(e.render(), b"E_ARG fn filter: bad pattern");
        let e = run("filter", vec![Value::list(vec![Value::Int(1)]), s("*")]).unwrap_err();
        assert_eq!(e.render(), b"E_TYPE fn filter element 0: expected str, got int");
    }

    #[test]
    fn arity_and_types() {
        let e = run("upper", vec![s("a"), s("b")]).unwrap_err();
        assert_eq!(e.render(), b"E_ARITY fn upper: expected 1, got 2");
        let e = run("pathjoin", vec![]).unwrap_err();
        assert_eq!(e.render(), b"E_ARITY fn pathjoin: expected 1-8, got 0");
        let e = run("upper", vec![Value::Int(1)]).unwrap_err();
        assert_eq!(e.render(), b"E_TYPE fn upper argument 1: expected str, got int");
    }

    #[test]
    fn list_functions() {
        let l = Value::list(vec![Value::Int(3), s("a"), Value::Int(3), Value::Bool(true)]);
        assert_eq!(
            run("uniq", vec![l.clone()]).unwrap(),
            Value::list(vec![Value::Int(3), s("a"), Value::Bool(true)])
        );
        assert_eq!(
            run("sort", vec![l.clone()]).unwrap(),
            Value::list(vec![Value::Bool(true), Value::Int(3), Value::Int(3), s("a")])
        );
        assert_eq!(run("indexof", vec![l.clone(), s("a")]).unwrap(), Value::Int(1));
        assert_eq!(run("indexof", vec![l, s("zz")]).unwrap(), Value::Int(-1));
        let nested = Value::list(vec![Value::list(vec![Value::Int(1)]), Value::Int(2), Value::list(vec![Value::list(vec![])])]);
        assert_eq!(
            run("flatten", vec![nested]).unwrap(),
            Value::list(vec![Value::Int(1), Value::Int(2), Value::list(vec![])])
        );
    }

    #[test]
    fn find_basics() {
        assert_eq!(find(b"abcabc", b"ca", 0), Some(2));
        assert_eq!(find(b"abc", b"", 5), Some(3));
        assert_eq!(find(b"ab", b"abc", 0), None);
        assert_eq!(find(b"aab", b"ab", 0), Some(1));
    }
}
