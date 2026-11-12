//! The built-in functions (section 15).

use crate::builtins::Builtin as B;
use crate::numfmt;
use crate::value::*;
use crate::vm::{Panic, Vm};
use std::cell::RefCell;
use std::rc::Rc;

fn int(v: &Value) -> i64 {
    match v {
        Value::Int(i) => *i,
        _ => unreachable!("expected Int"),
    }
}
fn flt(v: &Value) -> f64 {
    match v {
        Value::Float(f) => *f,
        _ => unreachable!("expected Float"),
    }
}
fn chr(v: &Value) -> char {
    match v {
        Value::Char(c) => *c,
        _ => unreachable!("expected Char"),
    }
}
fn string(v: &Value) -> &Rc<Vec<char>> {
    match v {
        Value::Str(s) => s,
        _ => unreachable!("expected Str"),
    }
}
fn list(v: &Value) -> &Rc<RefCell<Vec<Value>>> {
    match v {
        Value::List(l) => l,
        _ => unreachable!("expected list"),
    }
}
fn map(v: &Value) -> &Rc<RefCell<MapObj>> {
    match v {
        Value::Map(m) => m,
        _ => unreachable!("expected map"),
    }
}
fn mk_str(v: Vec<char>) -> Value {
    Value::Str(Rc::new(v))
}
fn mk_string(s: &str) -> Value {
    Value::str_of(s)
}
fn some(v: Value) -> Value {
    Value::Enum(Rc::new(EnumVal { decl: 0, variant: 0, fields: vec![v] }))
}
fn pair(a: Value, b: Value) -> Value {
    Value::Tuple(Rc::new(vec![a, b]))
}
fn panic<T>(msg: &str) -> Result<T, Panic> {
    Err(msg.to_string())
}

fn is_space(c: char) -> bool {
    matches!(c, '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ')
}

fn escape_into(out: &mut Vec<char>, c: char, quote: char) {
    match c {
        '\\' => out.extend(['\\', '\\']),
        '\n' => out.extend(['\\', 'n']),
        '\r' => out.extend(['\\', 'r']),
        '\t' => out.extend(['\\', 't']),
        c if c == quote => out.extend(['\\', c]),
        c if (c as u32) < 0x20 || c as u32 == 0x7f => {
            out.extend("\\u{".chars());
            out.extend(format!("{:x}", c as u32).chars());
            out.push('}');
        }
        c => out.push(c),
    }
}

fn find(hay: &[char], needle: &[char], from: usize) -> Option<usize> {
    if needle.is_empty() {
        return Some(from);
    }
    if hay.len() < needle.len() {
        return None;
    }
    let last = hay.len() - needle.len();
    let first = needle[0];
    let mut i = from;
    while i <= last {
        if hay[i] == first && hay[i..i + needle.len()] == *needle {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn cmp_float(a: f64, b: f64) -> i64 {
    match (a.is_nan(), b.is_nan()) {
        (true, true) => 0,
        (true, false) => 1,
        (false, true) => -1,
        _ => {
            if a < b {
                -1
            } else if a > b {
                1
            } else {
                0
            }
        }
    }
}

fn pow_f(x: f64, n: i64) -> Result<f64, Panic> {
    if n == i64::MIN {
        return panic("negative exponent");
    }
    let (m, neg) = if n < 0 { (-n, true) } else { (n, false) };
    let mut r = 1.0f64;
    let mut b = x;
    let mut k = m;
    while k > 0 {
        if k & 1 == 1 {
            r *= b;
        }
        k >>= 1;
        if k > 0 {
            b *= b;
        }
    }
    Ok(if neg { 1.0 / r } else { r })
}

impl<'p> Vm<'p> {
    fn none(&self) -> Value {
        self.prog.nullary[0][1].clone()
    }

    fn write_str(&mut self, s: &[char]) {
        let mut buf = [0u8; 4];
        for &c in s {
            if (c as u32) < 0x80 {
                self.out.push(c as u8);
            } else {
                self.out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
            }
        }
    }

    pub(crate) fn call_builtin(&mut self, b: B, argc: usize) -> Result<(), Panic> {
        let start = self.stack.len() - argc;
        let args: Vec<Value> = self.stack.split_off(start);
        let r = self.builtin(b, &args)?;
        self.stack.push(r);
        Ok(())
    }

    fn builtin(&mut self, b: B, a: &[Value]) -> Result<Value, Panic> {
        Ok(match b {
            // ---- output
            B::Print => {
                let s = string(&a[0]).clone();
                self.write_str(&s);
                self.out.push(b'\n');
                Value::Unit
            }
            B::Emit => {
                let s = string(&a[0]).clone();
                self.write_str(&s);
                Value::Unit
            }
            B::Panic => {
                let s: String = string(&a[0]).iter().collect();
                return Err(s);
            }
            // ---- integers
            B::IntMin => Value::Int(i64::MIN),
            B::IntMax => Value::Int(i64::MAX),
            B::AbsI => Value::Int(int(&a[0]).wrapping_abs()),
            B::MinI => Value::Int(int(&a[0]).min(int(&a[1]))),
            B::MaxI => Value::Int(int(&a[0]).max(int(&a[1]))),
            B::SignI => Value::Int(int(&a[0]).signum()),
            B::CmpI => Value::Int(match int(&a[0]).cmp(&int(&a[1])) {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Equal => 0,
                std::cmp::Ordering::Greater => 1,
            }),
            B::DivFloor => {
                let (x, y) = (int(&a[0]), int(&a[1]));
                if y == 0 {
                    return panic("divide by zero");
                }
                let q = x.wrapping_div(y);
                let r = x.wrapping_rem(y);
                Value::Int(if r != 0 && ((r < 0) != (y < 0)) { q.wrapping_sub(1) } else { q })
            }
            B::ModFloor => {
                let (x, y) = (int(&a[0]), int(&a[1]));
                if y == 0 {
                    return panic("modulo by zero");
                }
                let r = x.wrapping_rem(y);
                Value::Int(if r != 0 && ((r < 0) != (y < 0)) { r.wrapping_add(y) } else { r })
            }
            B::PowI => {
                let (base, exp) = (int(&a[0]), int(&a[1]));
                if exp < 0 {
                    return panic("negative exponent");
                }
                let mut r: i64 = 1;
                let mut bb = base;
                let mut k = exp;
                while k > 0 {
                    if k & 1 == 1 {
                        r = r.wrapping_mul(bb);
                    }
                    k >>= 1;
                    if k > 0 {
                        bb = bb.wrapping_mul(bb);
                    }
                }
                Value::Int(r)
            }
            B::GcdI => {
                let mut x = int(&a[0]).unsigned_abs();
                let mut y = int(&a[1]).unsigned_abs();
                while y != 0 {
                    let t = x % y;
                    x = y;
                    y = t;
                }
                Value::Int(x as i64)
            }
            B::PopCount => Value::Int(int(&a[0]).count_ones() as i64),
            B::Clz => Value::Int(int(&a[0]).leading_zeros() as i64),
            B::Ctz => Value::Int(int(&a[0]).trailing_zeros() as i64),
            B::ToFloat => Value::Float(int(&a[0]) as f64),
            B::ShowInt => mk_string(&int(&a[0]).to_string()),
            B::ShowIntRadix => {
                let r = int(&a[1]);
                if !(2..=36).contains(&r) {
                    return panic("radix out of range");
                }
                mk_string(&numfmt::show_int_radix(int(&a[0]), r as u32))
            }
            B::ParseInt => match numfmt::parse_int_radix(string(&a[0]), 10) {
                Some(v) => some(Value::Int(v)),
                None => self.none(),
            },
            B::ParseIntRadix => {
                let r = int(&a[1]);
                if !(2..=36).contains(&r) {
                    return panic("radix out of range");
                }
                match numfmt::parse_int_radix(string(&a[0]), r as u32) {
                    Some(v) => some(Value::Int(v)),
                    None => self.none(),
                }
            }
            // ---- floats
            B::SqrtF => Value::Float(flt(&a[0]).sqrt()),
            B::AbsF => Value::Float(flt(&a[0]).abs()),
            B::FloorF => Value::Float(flt(&a[0]).floor()),
            B::CeilF => Value::Float(flt(&a[0]).ceil()),
            B::TruncF => Value::Float(flt(&a[0]).trunc()),
            B::RoundF => Value::Float(flt(&a[0]).round()),
            B::MinF => {
                let (x, y) = (flt(&a[0]), flt(&a[1]));
                Value::Float(if cmp_float(x, y) <= 0 { x } else { y })
            }
            B::MaxF => {
                let (x, y) = (flt(&a[0]), flt(&a[1]));
                Value::Float(if cmp_float(x, y) >= 0 { x } else { y })
            }
            B::FmodF => Value::Float(flt(&a[0]) % flt(&a[1])),
            B::PowF => Value::Float(pow_f(flt(&a[0]), int(&a[1]))?),
            B::IsNanF => Value::Bool(flt(&a[0]).is_nan()),
            B::IsInfF => Value::Bool(flt(&a[0]).is_infinite()),
            B::CmpF => Value::Int(cmp_float(flt(&a[0]), flt(&a[1]))),
            B::TruncToInt => {
                let t = flt(&a[0]).trunc();
                if !(t >= -9223372036854775808.0 && t < 9223372036854775808.0) {
                    return panic("float out of integer range");
                }
                Value::Int(t as i64)
            }
            B::ShowFloat => mk_string(&numfmt::show_float_at(flt(&a[0]), 6)),
            B::ShowFloatAt => {
                let d = int(&a[1]);
                if !(0..=17).contains(&d) {
                    return panic("digits out of range");
                }
                mk_string(&numfmt::show_float_at(flt(&a[0]), d as usize))
            }
            B::FloatBits => Value::Int(flt(&a[0]).to_bits() as i64),
            B::FloatFromBits => Value::Float(f64::from_bits(int(&a[0]) as u64)),
            B::ParseFloat => match numfmt::parse_float(string(&a[0])) {
                Some(v) => some(Value::Float(v)),
                None => self.none(),
            },
            B::InfF => Value::Float(f64::INFINITY),
            B::NanF => Value::Float(f64::from_bits(0x7ff8000000000000)),
            B::PiF => Value::Float(f64::from_bits(4614256656552045848)),
            // ---- bools and chars
            B::ShowBool => mk_string(if matches!(a[0], Value::Bool(true)) { "true" } else { "false" }),
            B::Ord => Value::Int(chr(&a[0]) as i64),
            B::Chr => {
                let n = int(&a[0]);
                if !(0..=0x10FFFF).contains(&n) || (0xD800..=0xDFFF).contains(&n) {
                    return panic("invalid char code");
                }
                Value::Char(char::from_u32(n as u32).unwrap())
            }
            B::IsDigit => Value::Bool(chr(&a[0]).is_ascii_digit()),
            B::IsAlpha => Value::Bool(chr(&a[0]).is_ascii_alphabetic()),
            B::IsAlnum => Value::Bool(chr(&a[0]).is_ascii_alphanumeric()),
            B::IsSpace => Value::Bool(is_space(chr(&a[0]))),
            B::IsUpper => Value::Bool(chr(&a[0]).is_ascii_uppercase()),
            B::IsLower => Value::Bool(chr(&a[0]).is_ascii_lowercase()),
            B::ToUpperC => Value::Char(chr(&a[0]).to_ascii_uppercase()),
            B::ToLowerC => Value::Char(chr(&a[0]).to_ascii_lowercase()),
            B::CmpC => Value::Int(match chr(&a[0]).cmp(&chr(&a[1])) {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Equal => 0,
                std::cmp::Ordering::Greater => 1,
            }),
            B::ShowChar => mk_str(vec![chr(&a[0])]),
            B::QuoteChar => {
                let mut v = vec!['\''];
                escape_into(&mut v, chr(&a[0]), '\'');
                v.push('\'');
                mk_str(v)
            }
            // ---- strings
            B::StrLen => Value::Int(string(&a[0]).len() as i64),
            B::CharAt => {
                let s = string(&a[0]);
                let i = int(&a[1]);
                if i < 0 || i as u64 >= s.len() as u64 {
                    return panic("index out of bounds");
                }
                Value::Char(s[i as usize])
            }
            B::Substr => {
                let s = string(&a[0]);
                let (f, t) = (int(&a[1]), int(&a[2]));
                if f < 0 || f > t || t as u64 > s.len() as u64 {
                    return panic("index out of bounds");
                }
                mk_str(s[f as usize..t as usize].to_vec())
            }
            B::StrCat => {
                let mut v = string(&a[0]).as_ref().clone();
                v.extend_from_slice(string(&a[1]));
                mk_str(v)
            }
            B::StrRepeat => {
                let n = int(&a[1]);
                if n < 0 {
                    return panic("negative count");
                }
                let s = string(&a[0]);
                let mut v = Vec::with_capacity(s.len() * n as usize);
                for _ in 0..n {
                    v.extend_from_slice(s);
                }
                mk_str(v)
            }
            B::StrIndexOf => {
                let (s, sub) = (string(&a[0]), string(&a[1]));
                Value::Int(find(s, sub, 0).map_or(-1, |i| i as i64))
            }
            B::StrLastIndexOf => {
                let (s, sub) = (string(&a[0]), string(&a[1]));
                let mut r = -1i64;
                if sub.len() <= s.len() {
                    let mut i = s.len() - sub.len();
                    loop {
                        if s[i..i + sub.len()] == **sub {
                            r = i as i64;
                            break;
                        }
                        if i == 0 {
                            break;
                        }
                        i -= 1;
                    }
                }
                Value::Int(r)
            }
            B::StrContains => Value::Bool(find(string(&a[0]), string(&a[1]), 0).is_some()),
            B::StartsWith => Value::Bool(string(&a[0]).starts_with(string(&a[1]))),
            B::EndsWith => Value::Bool(string(&a[0]).ends_with(string(&a[1]))),
            B::StrSplit => {
                let (s, sep) = (string(&a[0]), string(&a[1]));
                if sep.is_empty() {
                    return panic("empty separator");
                }
                let mut parts = Vec::new();
                let mut from = 0;
                while let Some(i) = find(s, sep, from) {
                    parts.push(mk_str(s[from..i].to_vec()));
                    from = i + sep.len();
                }
                parts.push(mk_str(s[from..].to_vec()));
                Value::list_of(parts)
            }
            B::StrJoin => {
                let sep = string(&a[1]);
                let parts = list(&a[0]).borrow();
                let mut v = Vec::new();
                for (i, p) in parts.iter().enumerate() {
                    if i > 0 {
                        v.extend_from_slice(sep);
                    }
                    v.extend_from_slice(string(p));
                }
                mk_str(v)
            }
            B::StrReplace => {
                let (s, from, to) = (string(&a[0]), string(&a[1]), string(&a[2]));
                if from.is_empty() {
                    return panic("empty separator");
                }
                let mut v = Vec::new();
                let mut i = 0;
                while i < s.len() {
                    if s[i..].starts_with(from) {
                        v.extend_from_slice(to);
                        i += from.len();
                    } else {
                        v.push(s[i]);
                        i += 1;
                    }
                }
                mk_str(v)
            }
            B::Trim | B::TrimLeft | B::TrimRight => {
                let s = string(&a[0]);
                let mut lo = 0;
                let mut hi = s.len();
                if b != B::TrimRight {
                    while lo < hi && is_space(s[lo]) {
                        lo += 1;
                    }
                }
                if b != B::TrimLeft {
                    while hi > lo && is_space(s[hi - 1]) {
                        hi -= 1;
                    }
                }
                mk_str(s[lo..hi].to_vec())
            }
            B::Upper => mk_str(string(&a[0]).iter().map(|c| c.to_ascii_uppercase()).collect()),
            B::Lower => mk_str(string(&a[0]).iter().map(|c| c.to_ascii_lowercase()).collect()),
            B::StrCmp => Value::Int(match string(&a[0]).as_slice().cmp(string(&a[1]).as_slice()) {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Equal => 0,
                std::cmp::Ordering::Greater => 1,
            }),
            B::Chars => Value::list_of(string(&a[0]).iter().map(|c| Value::Char(*c)).collect()),
            B::StrOfChars => mk_str(list(&a[0]).borrow().iter().map(chr).collect()),
            B::StrReverse => mk_str(string(&a[0]).iter().rev().cloned().collect()),
            B::QuoteStr => {
                let mut v = vec!['"'];
                for &c in string(&a[0]).iter() {
                    escape_into(&mut v, c, '"');
                }
                v.push('"');
                mk_str(v)
            }
            B::PadLeft | B::PadRight => {
                let s = string(&a[0]);
                let w = int(&a[1]);
                if w < 0 {
                    return panic("negative count");
                }
                let c = chr(&a[2]);
                if s.len() as i64 >= w {
                    a[0].clone()
                } else {
                    let pad = w as usize - s.len();
                    let mut v = Vec::with_capacity(w as usize);
                    if b == B::PadRight {
                        v.extend_from_slice(s);
                    }
                    v.extend(std::iter::repeat(c).take(pad));
                    if b == B::PadLeft {
                        v.extend_from_slice(s);
                    }
                    mk_str(v)
                }
            }
            // ---- lists
            B::ListNew => Value::list_of(Vec::new()),
            B::ListLen => Value::Int(list(&a[0]).borrow().len() as i64),
            B::Push => {
                list(&a[0]).borrow_mut().push(a[1].clone());
                Value::Unit
            }
            B::Pop => match list(&a[0]).borrow_mut().pop() {
                Some(v) => v,
                None => return panic("empty list"),
            },
            B::Insert => {
                let mut l = list(&a[0]).borrow_mut();
                let i = int(&a[1]);
                if i < 0 || i as u64 > l.len() as u64 {
                    return panic("index out of bounds");
                }
                l.insert(i as usize, a[2].clone());
                Value::Unit
            }
            B::RemoveAt => {
                let mut l = list(&a[0]).borrow_mut();
                let i = int(&a[1]);
                if i < 0 || i as u64 >= l.len() as u64 {
                    return panic("index out of bounds");
                }
                l.remove(i as usize)
            }
            B::Clear => {
                list(&a[0]).borrow_mut().clear();
                Value::Unit
            }
            B::ListRepeat => {
                let n = int(&a[1]);
                if n < 0 {
                    return panic("negative count");
                }
                Value::list_of(vec![a[0].clone(); n as usize])
            }
            B::ListConcat => {
                let mut v = list(&a[0]).borrow().clone();
                v.extend(list(&a[1]).borrow().iter().cloned());
                Value::list_of(v)
            }
            B::Slice => {
                let l = list(&a[0]).borrow();
                let (f, t) = (int(&a[1]), int(&a[2]));
                if f < 0 || f > t || t as u64 > l.len() as u64 {
                    return panic("index out of bounds");
                }
                Value::list_of(l[f as usize..t as usize].to_vec())
            }
            B::ListCopy => Value::list_of(list(&a[0]).borrow().clone()),
            B::ReverseList => {
                let mut v = list(&a[0]).borrow().clone();
                v.reverse();
                Value::list_of(v)
            }
            B::ListFirst => match list(&a[0]).borrow().first() {
                Some(v) => v.clone(),
                None => return panic("empty list"),
            },
            B::ListLast => match list(&a[0]).borrow().last() {
                Some(v) => v.clone(),
                None => return panic("empty list"),
            },
            B::ListMap => {
                let xs = list(&a[0]).clone();
                let mut out = Vec::new();
                let mut i = 0;
                loop {
                    let x = match xs.borrow().get(i) {
                        Some(x) => x.clone(),
                        None => break,
                    };
                    out.push(self.call_closure(&a[1], &[x])?);
                    i += 1;
                }
                Value::list_of(out)
            }
            B::ListFilter => {
                let xs = list(&a[0]).clone();
                let mut out = Vec::new();
                let mut i = 0;
                loop {
                    let x = match xs.borrow().get(i) {
                        Some(x) => x.clone(),
                        None => break,
                    };
                    if matches!(self.call_closure(&a[1], &[x.clone()])?, Value::Bool(true)) {
                        out.push(x);
                    }
                    i += 1;
                }
                Value::list_of(out)
            }
            B::ListFold => {
                let xs = list(&a[0]).clone();
                let mut acc = a[1].clone();
                let mut i = 0;
                loop {
                    let x = match xs.borrow().get(i) {
                        Some(x) => x.clone(),
                        None => break,
                    };
                    acc = self.call_closure(&a[2], &[acc, x])?;
                    i += 1;
                }
                acc
            }
            B::ListAny | B::ListAll => {
                let xs = list(&a[0]).clone();
                let want = b == B::ListAny;
                let mut i = 0;
                let mut result = !want;
                loop {
                    let x = match xs.borrow().get(i) {
                        Some(x) => x.clone(),
                        None => break,
                    };
                    let r = matches!(self.call_closure(&a[1], &[x])?, Value::Bool(true));
                    if r == want {
                        result = want;
                        break;
                    }
                    i += 1;
                }
                Value::Bool(result)
            }
            B::ListFind | B::ListFindIndex => {
                let xs = list(&a[0]).clone();
                let mut i = 0;
                let mut found: Option<(usize, Value)> = None;
                loop {
                    let x = match xs.borrow().get(i) {
                        Some(x) => x.clone(),
                        None => break,
                    };
                    if matches!(self.call_closure(&a[1], &[x.clone()])?, Value::Bool(true)) {
                        found = Some((i, x));
                        break;
                    }
                    i += 1;
                }
                if b == B::ListFind {
                    match found {
                        Some((_, x)) => some(x),
                        None => self.none(),
                    }
                } else {
                    Value::Int(found.map_or(-1, |(i, _)| i as i64))
                }
            }
            B::ListIndexOf | B::ListContains => {
                let l = list(&a[0]).borrow();
                let idx = l.iter().position(|x| value_eq(x, &a[1]));
                if b == B::ListIndexOf {
                    Value::Int(idx.map_or(-1, |i| i as i64))
                } else {
                    Value::Bool(idx.is_some())
                }
            }
            B::ListZip => {
                let (x, y) = (list(&a[0]).borrow(), list(&a[1]).borrow());
                let n = x.len().min(y.len());
                Value::list_of((0..n).map(|i| pair(x[i].clone(), y[i].clone())).collect())
            }
            B::ListFlatten => {
                let outer = list(&a[0]).borrow();
                let mut v = Vec::new();
                for inner in outer.iter() {
                    v.extend(list(inner).borrow().iter().cloned());
                }
                Value::list_of(v)
            }
            B::SortBy => {
                let src0: Vec<Value> = list(&a[0]).borrow().clone();
                let n = src0.len();
                if n <= 1 {
                    return Ok(Value::list_of(src0));
                }
                let mut src = src0;
                let mut dst = src.clone();
                let mut width = 1;
                while width < n {
                    let mut i = 0;
                    while i < n {
                        let lo = i;
                        let mid = (i + width).min(n);
                        let hi = (i + 2 * width).min(n);
                        let (mut x, mut y, mut k) = (lo, mid, lo);
                        while x < mid && y < hi {
                            let c = self.call_closure(&a[1], &[src[x].clone(), src[y].clone()])?;
                            if int(&c) <= 0 {
                                dst[k] = src[x].clone();
                                x += 1;
                            } else {
                                dst[k] = src[y].clone();
                                y += 1;
                            }
                            k += 1;
                        }
                        while x < mid {
                            dst[k] = src[x].clone();
                            x += 1;
                            k += 1;
                        }
                        while y < hi {
                            dst[k] = src[y].clone();
                            y += 1;
                            k += 1;
                        }
                        i += 2 * width;
                    }
                    std::mem::swap(&mut src, &mut dst);
                    width *= 2;
                }
                Value::list_of(src)
            }
            // ---- maps
            B::MapNew => Value::Map(Rc::new(RefCell::new(MapObj::new()))),
            B::MapLen => Value::Int(map(&a[0]).borrow().len() as i64),
            B::MapHas => Value::Bool(map(&a[0]).borrow().contains(&a[1])),
            B::MapGet => match map(&a[0]).borrow().get(&a[1]) {
                Some(v) => some(v.clone()),
                None => self.none(),
            },
            B::MapGetOr => match map(&a[0]).borrow().get(&a[1]) {
                Some(v) => v.clone(),
                None => a[2].clone(),
            },
            B::MapSet => {
                map(&a[0]).borrow_mut().insert(a[1].clone(), a[2].clone());
                Value::Unit
            }
            B::MapDel => Value::Bool(map(&a[0]).borrow_mut().remove(&a[1])),
            B::KeysOf => Value::list_of(map(&a[0]).borrow().iter().map(|e| e.0.clone()).collect()),
            B::ValuesOf => Value::list_of(map(&a[0]).borrow().iter().map(|e| e.1.clone()).collect()),
            B::PairsOf => Value::list_of(
                map(&a[0]).borrow().iter().map(|e| pair(e.0.clone(), e.1.clone())).collect(),
            ),
            B::MapClear => {
                map(&a[0]).borrow_mut().clear();
                Value::Unit
            }
            B::MapCopy => {
                let mut m = MapObj::new();
                for e in map(&a[0]).borrow().iter() {
                    m.insert(e.0.clone(), e.1.clone());
                }
                Value::Map(Rc::new(RefCell::new(m)))
            }
            // ---- option / result / tuples
            B::IsSome => Value::Bool(matches!(&a[0], Value::Enum(e) if e.variant == 0)),
            B::IsNone => Value::Bool(matches!(&a[0], Value::Enum(e) if e.variant == 1)),
            B::Unwrap => match &a[0] {
                Value::Enum(e) if e.variant == 0 => e.fields[0].clone(),
                _ => return panic("unwrap of None"),
            },
            B::UnwrapOr => match &a[0] {
                Value::Enum(e) if e.variant == 0 => e.fields[0].clone(),
                _ => a[1].clone(),
            },
            B::IsOk => Value::Bool(matches!(&a[0], Value::Enum(e) if e.variant == 0)),
            B::IsErr => Value::Bool(matches!(&a[0], Value::Enum(e) if e.variant == 1)),
            B::UnwrapOk => match &a[0] {
                Value::Enum(e) if e.variant == 0 => e.fields[0].clone(),
                _ => return panic("unwrap of Err"),
            },
            B::UnwrapErr => match &a[0] {
                Value::Enum(e) if e.variant == 1 => e.fields[0].clone(),
                _ => return panic("unwrap of Ok"),
            },
            B::Fst => match &a[0] {
                Value::Tuple(t) => t[0].clone(),
                _ => unreachable!(),
            },
            B::Snd => match &a[0] {
                Value::Tuple(t) => t[1].clone(),
                _ => unreachable!(),
            },
            // ---- formatting
            B::Fmt => {
                let t = string(&a[0]);
                let args = list(&a[1]).borrow();
                let mut out: Vec<char> = Vec::new();
                let mut used = 0usize;
                let mut i = 0;
                while i < t.len() {
                    let c = t[i];
                    if c == '{' {
                        match t.get(i + 1) {
                            Some('{') => {
                                out.push('{');
                                i += 2;
                            }
                            Some('}') => {
                                if used < args.len() {
                                    out.extend_from_slice(string(&args[used]));
                                }
                                used += 1;
                                i += 2;
                            }
                            _ => return panic("bad format"),
                        }
                    } else if c == '}' {
                        if t.get(i + 1) == Some(&'}') {
                            out.push('}');
                            i += 2;
                        } else {
                            return panic("bad format");
                        }
                    } else {
                        out.push(c);
                        i += 1;
                    }
                }
                if used != args.len() {
                    return panic("bad format");
                }
                mk_str(out)
            }
        })
    }
}
