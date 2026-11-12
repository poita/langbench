//! Run-time behaviour: output, panics, integer and float semantics,
//! closures, patterns and the standard library.

mod common;
use common::*;

fn out(body: &str, expected: &str) {
    assert_eq!(run_main(body), expected, "program:\n{}", body);
}

#[test]
fn print_emit_and_panic_share_a_line() {
    out("fn main() { emit(\"a\"); panic(\"boom\"); }", "apanic: boom\n");
    out("fn main() { print(\"x\"); print(showInt(1 / 0)); }", "x\npanic: divide by zero\n");
}

#[test]
fn integer_semantics() {
    out(
        "fn main() {
            print(showInt(intMax() + 1));
            print(showInt(-7 / 2) ++ \" \" ++ showInt(-7 % 2));
            print(showInt(divFloor(-7, 2)) ++ \" \" ++ showInt(modFloor(-7, 2)));
            print(showInt(intMin() / -1) ++ \" \" ++ showInt(intMin() % -1));
            print(showInt(1 << 63) ++ \" \" ++ showInt(-16 >> 2));
            print(showInt(0x0f & 0x1c) ++ showInt(5 | 2) ++ showInt(~0) ++ showInt(6 ^ 3));
            print(showInt(popCount(-1)) ++ \" \" ++ showInt(clz(0)) ++ \" \" ++ showInt(ctz(0)));
            print(showInt(gcdI(intMin(), intMin())));
        }",
        "-9223372036854775808\n-3 -1\n-4 1\n-9223372036854775808 0\n-9223372036854775808 -4\n127-15\n64 64 64\n-9223372036854775808\n",
    );
}

#[test]
fn shifts_out_of_range_panic() {
    out("fn main() { print(showInt(1 << 64)); }", "panic: shift amount out of range\n");
    out("fn main() { print(showInt(1 >> -1)); }", "panic: shift amount out of range\n");
    out("fn main() { print(showInt(5 % 0)); }", "panic: modulo by zero\n");
}

#[test]
fn float_semantics() {
    out(
        "fn main() {
            print(showFloat(0.1 + 0.2));
            print(showFloatAt(0.1 + 0.2, 17));
            print(showFloatAt(2.5, 0) ++ showFloatAt(3.5, 0) ++ showFloatAt(0.5, 0));
            print(showFloatAt(2.675, 2));
            print(showFloat(-0.0) ++ \" \" ++ showFloat(1.0 / 0.0) ++ \" \" ++ showFloat(0.0 / 0.0));
            print(showBool(nanF() == nanF()) ++ showBool(-0.0 == 0.0) ++ showBool(-0.0 < 0.0));
            print(showFloat(roundF(2.5)) ++ \" \" ++ showFloat(roundF(-2.5)) ++ \" \" ++ showFloat(ceilF(-0.5)));
            print(showInt(truncToInt(-3.9)) ++ \" \" ++ showInt(cmpF(nanF(), 1.0)));
            print(showFloat(powF(2.0, -2)) ++ \" \" ++ showFloat(minF(nanF(), 1.0)));
        }",
        "0.300000\n0.30000000000000004\n240\n2.67\n-0.000000 inf nan\nfalsetruefalse\n3.000000 -3.000000 -0.000000\n-3 1\n0.250000 1.000000\n",
    );
    out("fn main() { print(showInt(truncToInt(nanF()))); }", "panic: float out of integer range\n");
    out("fn main() { print(showFloatAt(1.0, 18)); }", "panic: digits out of range\n");
}

#[test]
fn strings_are_scalar_sequences() {
    out(
        "fn main() {
            let s = \"héllo, wörld\";
            print(showInt(strLen(s)) ++ showChar(charAt(s, 1)) ++ substr(s, 7, 12));
            print(upper(s));
            print(strJoin(strSplit(\"a,,b,\", \",\"), \"|\"));
            print(strReplace(\"aaa\", \"aa\", \"b\"));
            print(quoteStr(\"tab\\there\\n\") ++ quoteChar('\\''));
            print(showInt(strIndexOf(s, \"l\")) ++ \" \" ++ showInt(strLastIndexOf(s, \"l\")));
            print(fmt(\"{{{}}} {}\", [\"x\", \"y\"]));
        }",
        "12éwörld\nHéLLO, WöRLD\na||b|\nba\n\"tab\\there\\n\"'\\''\n2 10\n{x} y\n",
    );
    out("fn main() { print(fmt(\"{} {}\", [\"x\"])); }", "panic: bad format\n");
    out("fn main() { print(showChar(charAt(\"abc\", 3))); }", "panic: index out of bounds\n");
}

#[test]
fn lists_and_maps_have_reference_semantics() {
    out(
        "fn main() {
            let a = [1, 2];
            let b = a;
            push(b, 3);
            print(showInt(listLen(a)));
            let c = listCopy(a);
            push(c, 4);
            print(showInt(listLen(a)) ++ showInt(listLen(c)));
            var m = #[\"x\": 1];
            m[\"y\"] = 2;
            mapDel(m, \"x\");
            m[\"x\"] = 3;
            print(strJoin(keysOf(m), \",\"));
            print(showBool(#[1: 2, 3: 4] == #[3: 4, 1: 2]));
            print(showBool([1, 2] ++ [3] == [1, 2, 3]));
        }",
        "3\n34\ny,x\ntrue\ntrue\n",
    );
}

#[test]
fn for_loops_see_list_changes() {
    out(
        "fn main() {
            let xs = [1, 2];
            var n = 0;
            for x in xs { if x < 3 { push(xs, x + 2); } n = n + 1; }
            print(showInt(n));
            for i in 3 .. 1 { print(\"never\"); }
        }",
        "4\n",
    );
}

#[test]
fn closures_capture_by_value() {
    out(
        "fn counter(start: Int) -> fn(Int) -> Int {
            var base = start;
            let f = |d: Int| base + d;
            base = base + 100;
            f
        }
        fn main() {
            print(showInt(counter(1)(5)));
            var fs: [fn() -> Int] = listNew();
            for i in 0 .. 4 { push(fs, || i * i); }
            var acc = 0;
            for g in fs { acc = acc + g(); }
            print(showInt(acc));
        }",
        "6\n14\n",
    );
}

#[test]
fn struct_literal_fields_evaluate_in_written_order() {
    out(
        "struct P { a: Int, b: Int }
        fn t(s: Str, n: Int) -> Int { emit(s); n }
        fn main() { let p = P.{ b: t(\"b\", 2), a: t(\"a\", 1) }; print(\" \" ++ showInt(p.a * 10 + p.b)); }",
        "ba 12\n",
    );
}

#[test]
fn call_depth_limit() {
    let prog = |n: i64| {
        format!(
            "fn rec(n: Int) -> Int {{ if n > 0 {{ 1 + rec(n - 1) }} else {{ 0 }} }}\nfn main() {{ print(showInt(rec({}))); }}",
            n
        )
    };
    assert_eq!(run_main(&prog(19998)), "19998\n");
    assert_eq!(run_main(&prog(19999)), "panic: call stack overflow\n");
}

#[test]
fn traits_dispatch_on_runtime_tags() {
    out(
        "trait Show { fn show(self) -> Str; fn twice(self) -> Str { self.show() ++ self.show() } }
        impl Show for Int { fn show(self) -> Str { showInt(self) } }
        impl<T: Show> Show for [T] { fn show(self) -> Str { strJoin(listMap(self, |x| x.show()), \"+\") } }
        enum Opt<T> { Sm(T), Nn }
        impl<T: Show> Show for Opt<T> {
            fn show(self) -> Str { match self { Sm(x) -> \"S\" ++ x.show(), Nn -> \"N\" } }
        }
        fn main() {
            print([1, 2].twice());
            print(Sm(3).twice());
            let o: Opt<Int> = Nn;
            print(Show::show(o));
        }",
        "1+21+2\nS3S3\nN\n",
    );
}

#[test]
fn sort_by_is_stable_and_follows_the_specified_merge_order() {
    out(
        "fn main() {
            let xs = [(2, \"a\"), (1, \"b\"), (2, \"c\"), (1, \"d\")];
            let ys = sortBy(xs, |p, q| cmpI(fst(p), fst(q)));
            print(strJoin(listMap(ys, |p| snd(p)), \"\"));
            let log: [Str] = listNew();
            let zs = sortBy([3, 1, 2], |a, b| { push(log, showInt(a) ++ showInt(b)); cmpI(a, b) });
            print(strJoin(log, \",\"));
        }",
        "bdac\n31,12,32\n",
    );
}
