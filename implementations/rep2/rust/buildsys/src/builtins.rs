//! The 39 built-in functions of KBL.

use std::collections::HashSet;
use std::rc::Rc;

use crate::error::{Error, ErrorKind, Result};
use crate::glob::Pattern;
use crate::value::Value;
use crate::workspace::Workspace;

/// Parameter types of built-in functions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ty {
    Str,
    Int,
    List,
    Any,
    StrList,
    StrInt,
    StrIntBool,
}

impl Ty {
    fn token(self) -> &'static str {
        match self {
            Ty::Str => "str",
            Ty::Int => "int",
            Ty::List => "list",
            Ty::Any => "any",
            Ty::StrList => "str|list",
            Ty::StrInt => "str|int",
            Ty::StrIntBool => "str|int|bool",
        }
    }

    fn accepts(self, v: &Value) -> bool {
        match self {
            Ty::Any => true,
            Ty::Str => matches!(v, Value::Str(_)),
            Ty::Int => matches!(v, Value::Int(_)),
            Ty::List => matches!(v, Value::List(_)),
            Ty::StrList => matches!(v, Value::Str(_) | Value::List(_)),
            Ty::StrInt => matches!(v, Value::Str(_) | Value::Int(_)),
            Ty::StrIntBool => matches!(v, Value::Str(_) | Value::Int(_) | Value::Bool(_)),
        }
    }
}

/// A built-in function's name and signature.
pub struct Builtin {
    pub name: &'static str,
    min: usize,
    tys: &'static [Ty],
}

use Ty::{Any, Int, List, Str, StrInt, StrIntBool, StrList};

const fn f(name: &'static str, tys: &'static [Ty]) -> Builtin {
    Builtin {
        name,
        min: tys.len(),
        tys,
    }
}

static TABLE: [Builtin; 39] = [
    f("len", &[StrList]),
    f("count", &[List]),
    f("upper", &[Str]),
    f("lower", &[Str]),
    f("trim", &[Str]),
    f("replace", &[Str, Str, Str]),
    f("starts_with", &[Str, Str]),
    f("ends_with", &[Str, Str]),
    f("contains", &[Str, Str]),
    f("substr", &[Str, Int, Int]),
    f("split", &[Str, Str]),
    f("join", &[List, Str]),
    f("str", &[StrIntBool]),
    f("int", &[StrInt]),
    f("dirname", &[Str]),
    f("basename", &[Str]),
    f("stem", &[Str]),
    f("ext", &[Str]),
    Builtin {
        name: "pathjoin",
        min: 1,
        tys: &[Str, Str, Str, Str, Str, Str, Str, Str],
    },
    f("map", &[List, Str]),
    f("filter", &[List, Str]),
    f("reject", &[List, Str]),
    f("sort", &[List]),
    f("uniq", &[List]),
    f("reverse", &[List]),
    f("first", &[List]),
    f("last", &[List]),
    f("slice", &[List, Int, Int]),
    f("has", &[List, Any]),
    f("indexof", &[List, Any]),
    f("range", &[Int]),
    f("sum", &[List]),
    f("flatten", &[List]),
    f("zip", &[List, List]),
    f("is_str", &[Any]),
    f("is_int", &[Any]),
    f("is_bool", &[Any]),
    f("is_list", &[Any]),
    f("glob", &[Str]),
];

/// Looks up a built-in function by name.
pub fn lookup(name: &str) -> Option<&'static Builtin> {
    TABLE.iter().find(|b| b.name == name)
}

/// Decimal text of an integer.
pub fn int_text(i: i64) -> Vec<u8> {
    i.to_string().into_bytes()
}

/// Left-to-right non-overlapping replacement; `from` must be non-empty.
pub fn replace_bytes(s: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == from[0] && s[i..].starts_with(from) {
            out.extend_from_slice(to);
            i += from.len();
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    out
}

fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() {
        return Some(from);
    }
    let mut i = from;
    while i + needle.len() <= hay.len() {
        if hay[i] == needle[0] && hay[i..].starts_with(needle) {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Clamps `(start, count)` as `substr` and `slice` do for a length `n`.
fn clamp_range(n: usize, start: i64, count: i64) -> (usize, usize) {
    let n_i = n as i64;
    let mut s = start;
    if s < 0 {
        s = n_i.saturating_add(s);
    }
    let s = s.clamp(0, n_i);
    let c = count.clamp(0, n_i - s);
    (s as usize, c as usize)
}

fn basename(s: &[u8]) -> &[u8] {
    match s.iter().rposition(|&b| b == b'/') {
        Some(i) => &s[i + 1..],
        None => s,
    }
}

/// Splits a basename into (stem, ext) at the last '.' not at index 0.
fn split_ext(b: &[u8]) -> (&[u8], &[u8]) {
    match b.iter().rposition(|&c| c == b'.') {
        Some(i) if i > 0 => (&b[..i], &b[i..]),
        _ => (b, &[]),
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
    let mut v: i64 = 0;
    for &d in digits {
        let d = i64::from(d - b'0');
        v = v.checked_mul(10)?;
        v = if neg { v.checked_sub(d)? } else { v.checked_add(d)? };
    }
    Some(v)
}

fn compile(name: &str, pat: &[u8]) -> Result<Pattern> {
    Pattern::compile(pat).ok_or_else(|| Error::arg("fn", name, "bad pattern"))
}

fn bool_v(b: bool) -> Result<Value> {
    Ok(Value::Bool(b))
}

fn elem_err(name: &str, i: usize, expected: &str, v: &Value) -> Error {
    Error::type_mismatch(
        &format!("fn {name} element {i}"),
        expected,
        v.type_name(),
    )
}

/// Calls built-in `b` with already evaluated arguments: checks arity and
/// argument types, then runs the function.
pub fn call(b: &Builtin, args: &[Value], ws: &Workspace) -> Result<Value> {
    let name = b.name;
    if args.len() < b.min || args.len() > b.tys.len() {
        let expected = if b.min == b.tys.len() {
            b.min.to_string()
        } else {
            format!("{}-{}", b.min, b.tys.len())
        };
        return Err(Error::arity("fn", name, &expected, args.len()));
    }
    for (i, (a, ty)) in args.iter().zip(b.tys).enumerate() {
        if !ty.accepts(a) {
            return Err(Error::type_mismatch(
                &format!("fn {name} argument {}", i + 1),
                ty.token(),
                a.type_name(),
            ));
        }
    }
    let a0 = &args[0];
    match name {
        "len" => Ok(Value::Int(match a0 {
            Value::Str(s) => s.len(),
            other => other.as_list().len(),
        } as i64)),
        "count" => Ok(Value::Int(a0.as_list().len() as i64)),
        "upper" => Ok(Value::str(a0.as_bytes().to_ascii_uppercase())),
        "lower" => Ok(Value::str(a0.as_bytes().to_ascii_lowercase())),
        "trim" => {
            let ws_byte = |c: &u8| matches!(c, b' ' | b'\t' | b'\n' | b'\r');
            let s = a0.as_bytes();
            let start = s.iter().position(|c| !ws_byte(c)).unwrap_or(s.len());
            let end = s.iter().rposition(|c| !ws_byte(c)).map_or(start, |i| i + 1);
            Ok(Value::str(&s[start..end]))
        }
        "replace" => {
            let from = args[1].as_bytes();
            if from.is_empty() {
                return Err(Error::arg("fn", "replace", "empty pattern"));
            }
            Ok(Value::str(replace_bytes(a0.as_bytes(), from, args[2].as_bytes())))
        }
        "starts_with" => bool_v(a0.as_bytes().starts_with(args[1].as_bytes())),
        "ends_with" => bool_v(a0.as_bytes().ends_with(args[1].as_bytes())),
        "contains" => bool_v(find(a0.as_bytes(), args[1].as_bytes(), 0).is_some()),
        "substr" => {
            let s = a0.as_bytes();
            let (st, c) = clamp_range(s.len(), args[1].as_int(), args[2].as_int());
            Ok(Value::str(&s[st..st + c]))
        }
        "split" => {
            let s = a0.as_bytes();
            let sep = args[1].as_bytes();
            if sep.is_empty() {
                return Err(Error::arg("fn", "split", "empty separator"));
            }
            let mut out = Vec::new();
            let mut start = 0;
            while let Some(i) = find(s, sep, start) {
                out.push(Value::str(&s[start..i]));
                start = i + sep.len();
            }
            out.push(Value::str(&s[start..]));
            Ok(Value::list(out))
        }
        "join" => {
            let sep = args[1].as_bytes();
            let mut out = Vec::new();
            for (i, v) in a0.as_list().iter().enumerate() {
                if i > 0 {
                    out.extend_from_slice(sep);
                }
                match v {
                    Value::Str(s) => out.extend_from_slice(s),
                    Value::Int(n) => out.extend_from_slice(&int_text(*n)),
                    other => return Err(elem_err("join", i, "str|int", other)),
                }
            }
            Ok(Value::str(out))
        }
        "str" => Ok(match a0 {
            Value::Str(_) => a0.clone(),
            Value::Int(n) => Value::str(int_text(*n)),
            Value::Bool(b) => Value::str(if *b { "true" } else { "false" }),
            Value::List(_) => return Err(Error::new(ErrorKind::Interp, "list")),
        }),
        "int" => match a0 {
            Value::Int(_) => Ok(a0.clone()),
            _ => parse_int(a0.as_bytes())
                .map(Value::Int)
                .ok_or_else(|| Error::arg("fn", "int", "bad integer")),
        },
        "dirname" => {
            let s = a0.as_bytes();
            Ok(Value::str(match s.iter().rposition(|&c| c == b'/') {
                Some(i) => &s[..i],
                None => &[][..],
            }))
        }
        "basename" => Ok(Value::str(basename(a0.as_bytes()))),
        "stem" => Ok(Value::str(split_ext(basename(a0.as_bytes())).0)),
        "ext" => Ok(Value::str(split_ext(basename(a0.as_bytes())).1)),
        "pathjoin" => {
            let mut out = Vec::new();
            let mut first = true;
            for a in args {
                if a.as_bytes().is_empty() {
                    continue;
                }
                if !first {
                    out.push(b'/');
                }
                first = false;
                out.extend_from_slice(a.as_bytes());
            }
            Ok(Value::str(out))
        }
        "map" => {
            let pat = args[1].as_bytes();
            let mut out = Vec::new();
            for (i, v) in a0.as_list().iter().enumerate() {
                let Value::Str(s) = v else {
                    return Err(elem_err("map", i, "str", v));
                };
                let mut r = Vec::with_capacity(pat.len() + s.len());
                let mut k = 0;
                while k < pat.len() {
                    if pat[k] == b'%' {
                        if pat.get(k + 1) == Some(&b'%') {
                            r.push(b'%');
                            k += 2;
                        } else {
                            r.extend_from_slice(s);
                            k += 1;
                        }
                    } else {
                        r.push(pat[k]);
                        k += 1;
                    }
                }
                out.push(Value::str(r));
            }
            Ok(Value::list(out))
        }
        "filter" | "reject" => {
            let pat = compile(name, args[1].as_bytes())?;
            let keep_matching = name == "filter";
            let mut out = Vec::new();
            for (i, v) in a0.as_list().iter().enumerate() {
                let Value::Str(s) = v else {
                    return Err(elem_err(name, i, "str", v));
                };
                if pat.is_match(s) == keep_matching {
                    out.push(v.clone());
                }
            }
            Ok(Value::list(out))
        }
        "sort" => {
            let mut v = a0.as_list().to_vec();
            v.sort();
            Ok(Value::list(v))
        }
        "uniq" => {
            let mut seen = HashSet::new();
            let mut out = Vec::new();
            for v in a0.as_list() {
                if seen.insert(v.clone()) {
                    out.push(v.clone());
                }
            }
            Ok(Value::list(out))
        }
        "reverse" => {
            let mut v = a0.as_list().to_vec();
            v.reverse();
            Ok(Value::list(v))
        }
        "first" => a0
            .as_list()
            .first()
            .cloned()
            .ok_or_else(|| Error::arg("fn", "first", "empty list")),
        "last" => a0
            .as_list()
            .last()
            .cloned()
            .ok_or_else(|| Error::arg("fn", "last", "empty list")),
        "slice" => {
            let l = a0.as_list();
            let (st, c) = clamp_range(l.len(), args[1].as_int(), args[2].as_int());
            Ok(Value::list(l[st..st + c].to_vec()))
        }
        "has" => bool_v(a0.as_list().contains(&args[1])),
        "indexof" => Ok(Value::Int(
            a0.as_list()
                .iter()
                .position(|v| *v == args[1])
                .map_or(-1, |i| i as i64),
        )),
        "range" => {
            let n = a0.as_int();
            if n < 0 {
                return Err(Error::arg("fn", "range", "negative"));
            }
            Ok(Value::list((0..n).map(Value::Int).collect()))
        }
        "sum" => {
            let mut total = 0i64;
            for (i, v) in a0.as_list().iter().enumerate() {
                match v {
                    Value::Int(n) => total = total.wrapping_add(*n),
                    other => return Err(elem_err("sum", i, "int", other)),
                }
            }
            Ok(Value::Int(total))
        }
        "flatten" => {
            let mut out = Vec::new();
            for v in a0.as_list() {
                match v {
                    Value::List(inner) => out.extend(inner.iter().cloned()),
                    other => out.push(other.clone()),
                }
            }
            Ok(Value::list(out))
        }
        "zip" => Ok(Value::list(
            a0.as_list()
                .iter()
                .zip(args[1].as_list())
                .map(|(a, b)| Value::list(vec![a.clone(), b.clone()]))
                .collect(),
        )),
        "is_str" => bool_v(matches!(a0, Value::Str(_))),
        "is_int" => bool_v(matches!(a0, Value::Int(_))),
        "is_bool" => bool_v(matches!(a0, Value::Bool(_))),
        "is_list" => bool_v(matches!(a0, Value::List(_))),
        "glob" => {
            let pat = compile("glob", a0.as_bytes())?;
            Ok(Value::List(Rc::new(
                ws.glob(&pat).into_iter().map(Value::str).collect(),
            )))
        }
        _ => unreachable!("builtin table and dispatch out of sync: {name}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(name: &str, args: Vec<Value>) -> Result<Value> {
        call(lookup(name).unwrap(), &args, &Workspace::new())
    }

    fn s(x: &str) -> Value {
        Value::str(x)
    }

    #[test]
    fn table_has_39_distinct_functions() {
        let names: HashSet<_> = TABLE.iter().map(|b| b.name).collect();
        assert_eq!(names.len(), 39);
    }

    #[test]
    fn substr_clamping() {
        let r = |a, b| run("substr", vec![s("abcdef"), Value::Int(a), Value::Int(b)]).unwrap();
        assert_eq!(r(1, 3), s("bcd"));
        assert_eq!(r(-2, 5), s("ef"));
        assert_eq!(r(10, 2), s(""));
        assert_eq!(r(2, -1), s(""));
        assert_eq!(r(-100, 2), s("ab"));
    }

    #[test]
    fn split_and_join() {
        let v = run("split", vec![s("a,,b"), s(",")]).unwrap();
        assert_eq!(v, Value::list(vec![s("a"), s(""), s("b")]));
        assert_eq!(
            run("split", vec![s(""), s(",")]).unwrap(),
            Value::list(vec![s("")])
        );
        assert_eq!(
            run("join", vec![Value::list(vec![s("a"), Value::Int(2)]), s("-")]).unwrap(),
            s("a-2")
        );
        let e = run("join", vec![Value::list(vec![s("a"), Value::Bool(true)]), s("-")]);
        assert_eq!(
            e.unwrap_err().to_string(),
            "E_TYPE fn join element 1: expected str|int, got bool"
        );
    }

    #[test]
    fn int_parsing() {
        assert_eq!(run("int", vec![s("-007")]).unwrap(), Value::Int(-7));
        assert_eq!(
            run("int", vec![s("-9223372036854775808")]).unwrap(),
            Value::Int(i64::MIN)
        );
        for bad in ["", "+1", " 1", "1 ", "-", "9223372036854775808", "1.0"] {
            assert!(run("int", vec![s(bad)]).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn path_functions() {
        let cases = [
            ("src/a.txt", "a", ".txt"),
            ("src/a.b.txt", "a.b", ".txt"),
            ("src/a", "a", ""),
            ("src/.hidden", ".hidden", ""),
            ("a.txt", "a", ".txt"),
            ("src/x.", "x", "."),
        ];
        for (p, st, ex) in cases {
            assert_eq!(run("stem", vec![s(p)]).unwrap(), s(st), "{p}");
            assert_eq!(run("ext", vec![s(p)]).unwrap(), s(ex), "{p}");
        }
        assert_eq!(run("dirname", vec![s("a/b/c")]).unwrap(), s("a/b"));
        assert_eq!(run("dirname", vec![s("c")]).unwrap(), s(""));
        assert_eq!(
            run("pathjoin", vec![s("out"), s(""), s("a.txt")]).unwrap(),
            s("out/a.txt")
        );
        assert_eq!(run("pathjoin", vec![s("out/")]).unwrap(), s("out/"));
        assert_eq!(
            run("pathjoin", vec![]).unwrap_err().to_string(),
            "E_ARITY fn pathjoin: expected 1-8, got 0"
        );
    }

    #[test]
    fn map_patterns() {
        let l = Value::list(vec![s("a"), s("b")]);
        assert_eq!(
            run("map", vec![l, s("out/%.o")]).unwrap(),
            Value::list(vec![s("out/a.o"), s("out/b.o")])
        );
        assert_eq!(
            run("map", vec![Value::list(vec![s("a")]), s("100%%-%")]).unwrap(),
            Value::list(vec![s("100%-a")])
        );
    }

    #[test]
    fn filter_compiles_pattern_first() {
        let e = run("filter", vec![Value::list(vec![Value::Int(1)]), s("")]);
        assert_eq!(e.unwrap_err().to_string(), "E_ARG fn filter: bad pattern");
        let e = run("reject", vec![Value::list(vec![Value::Int(1)]), s("*")]);
        assert_eq!(
            e.unwrap_err().to_string(),
            "E_TYPE fn reject element 0: expected str, got int"
        );
    }

    #[test]
    fn list_functions() {
        let l = Value::list(vec![Value::Int(3), Value::Int(1), Value::Int(3)]);
        assert_eq!(
            run("uniq", vec![l.clone()]).unwrap(),
            Value::list(vec![Value::Int(3), Value::Int(1)])
        );
        assert_eq!(run("sum", vec![l.clone()]).unwrap(), Value::Int(7));
        assert_eq!(run("indexof", vec![l.clone(), Value::Int(1)]).unwrap(), Value::Int(1));
        assert_eq!(run("indexof", vec![l, Value::Int(9)]).unwrap(), Value::Int(-1));
        assert_eq!(
            run("flatten", vec![Value::list(vec![Value::list(vec![Value::Int(1)]), Value::Int(2)])])
                .unwrap(),
            Value::list(vec![Value::Int(1), Value::Int(2)])
        );
        assert_eq!(
            run("first", vec![Value::list(vec![])]).unwrap_err().to_string(),
            "E_ARG fn first: empty list"
        );
    }
}
