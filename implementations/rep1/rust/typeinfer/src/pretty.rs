//! Rendering types as text.

use crate::types::{Kind, Ty, Types};

/// Where a type is being printed, which decides whether it needs parentheses.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Ctx {
    /// Top level or right of an arrow: nothing needs parentheses.
    Top,
    /// Left of an arrow: function types need parentheses.
    ArrowLeft,
    /// Tuple component or list element: functions and tuples need them.
    Component,
}

impl Types {
    /// Renders `t` in the notation of the specification. Unbound variables are
    /// named `'a`, `'b`, ... in order of first appearance, left to right.
    pub fn render(&mut self, t: Ty) -> String {
        self.begin_walk();
        let mut out = String::new();
        let mut next = 0u32;
        self.write(t, Ctx::Top, &mut out, &mut next);
        out
    }

    fn write(&mut self, t: Ty, ctx: Ctx, out: &mut String, next: &mut u32) {
        let t = self.repr(t);
        match self.kind(t) {
            Kind::Var(_) => {
                let n = if self.visited(t) {
                    Types::raw_index(self.memo(t))
                } else {
                    let n = *next;
                    *next += 1;
                    self.visit(t, Types::from_raw_index(n));
                    n
                };
                push_var_name(out, n);
            }
            Kind::Int => out.push_str("int"),
            Kind::Bool => out.push_str("bool"),
            Kind::Unit => out.push_str("unit"),
            Kind::Arrow(a, b) => {
                let paren = ctx >= Ctx::ArrowLeft;
                if paren {
                    out.push('(');
                }
                self.write(a, Ctx::ArrowLeft, out, next);
                out.push_str(" -> ");
                self.write(b, Ctx::Top, out, next);
                if paren {
                    out.push(')');
                }
            }
            Kind::List(a) => {
                self.write(a, Ctx::Component, out, next);
                out.push_str(" list");
            }
            Kind::Tuple(n) => {
                let paren = ctx == Ctx::Component;
                if paren {
                    out.push('(');
                }
                for i in 0..n {
                    if i > 0 {
                        out.push_str(" * ");
                    }
                    let c = self.tuple_component(t, i);
                    self.write(c, Ctx::Component, out, next);
                }
                if paren {
                    out.push(')');
                }
            }
        }
    }
}

fn push_var_name(out: &mut String, i: u32) {
    out.push('\'');
    out.push((b'a' + (i % 26) as u8) as char);
    if i >= 26 {
        out.push_str(&(i / 26).to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn variable_names() {
        let mut s = String::new();
        push_var_name(&mut s, 0);
        push_var_name(&mut s, 25);
        push_var_name(&mut s, 26);
        push_var_name(&mut s, 27 + 26 * 11);
        assert_eq!(s, "'a'z'a1'b12");
    }

    #[test]
    fn parenthesisation() {
        let mut ts = Types::new();
        let (i, b) = (ts.int(), ts.bool());
        let f = ts.arrow(i, i);
        let p = ts.tuple(vec![i, b]);
        let lf = ts.list(f);
        let lp = ts.list(p);
        let tup = ts.tuple(vec![f, p, i]);
        let fa = ts.arrow(f, p);
        let ta = ts.arrow(p, p);
        assert_eq!(ts.render(lf), "(int -> int) list");
        assert_eq!(ts.render(lp), "(int * bool) list");
        assert_eq!(ts.render(tup), "(int -> int) * (int * bool) * int");
        assert_eq!(ts.render(fa), "(int -> int) -> int * bool");
        assert_eq!(ts.render(ta), "int * bool -> int * bool");
    }

    #[test]
    fn shared_variable_is_named_once() {
        let mut ts = Types::new();
        let a = ts.var(1);
        let b = ts.var(1);
        let f = ts.arrow(a, b);
        let g = ts.arrow(b, a);
        let t = ts.arrow(f, g);
        assert_eq!(ts.render(t), "('a -> 'b) -> 'b -> 'a");
    }
}
