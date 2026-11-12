//! Converting values to text in the *write* and *display* forms.

use crate::value::Value;

/// The *write* form of a value: strings are quoted and escaped.
pub fn write_string(v: &Value) -> String {
    let mut out = String::new();
    print(&mut out, v, false);
    out
}

/// The *display* form of a value: strings appear raw, at any depth.
pub fn display_string(v: &Value) -> String {
    let mut out = String::new();
    print(&mut out, v, true);
    out
}

fn print(out: &mut String, v: &Value, display: bool) {
    match v {
        Value::Void => out.push_str("#<void>"),
        Value::Nil => out.push_str("()"),
        Value::Bool(true) => out.push_str("#t"),
        Value::Bool(false) => out.push_str("#f"),
        Value::Int(i) => out.push_str(&i.to_string()),
        Value::Big(b) => out.push_str(&b.to_string()),
        Value::Sym(s) => out.push_str(&s.name()),
        Value::Closure(_) | Value::Prim(_) => out.push_str("#<procedure>"),
        Value::Str(s) => {
            if display {
                out.push_str(s);
            } else {
                out.push('"');
                for c in s.chars() {
                    match c {
                        '\\' => out.push_str("\\\\"),
                        '"' => out.push_str("\\\""),
                        '\n' => out.push_str("\\n"),
                        '\t' => out.push_str("\\t"),
                        c => out.push(c),
                    }
                }
                out.push('"');
            }
        }
        Value::Pair(p) => {
            out.push('(');
            print(out, &p.car, display);
            let mut rest = &p.cdr;
            loop {
                match rest {
                    Value::Nil => break,
                    Value::Pair(q) => {
                        out.push(' ');
                        print(out, &q.car, display);
                        rest = &q.cdr;
                    }
                    tail => {
                        out.push_str(" . ");
                        print(out, tail, display);
                        break;
                    }
                }
            }
            out.push(')');
        }
    }
}
