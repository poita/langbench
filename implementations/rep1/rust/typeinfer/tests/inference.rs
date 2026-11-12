//! End-to-end tests of the library through its public API.

use typeinfer::{infer_program, infer_to_string, ParseError, Session, TypeError};

fn run(src: &str) -> String {
    infer_to_string(src).expect("program should parse")
}

fn check(src: &str, expected: &[&str]) {
    let got = run(src);
    let want: String = expected.iter().map(|l| format!("{}\n", l)).collect();
    assert_eq!(got, want, "source: {}", src);
}

#[test]
fn empty_program_has_no_output() {
    assert_eq!(run(""), "");
    assert_eq!(run("  \n\t\r\n "), "");
}

#[test]
fn spec_example_one() {
    check(
        "let id = fun x -> x;;
         let compose f g x = f (g x);;
         compose;;
         let rec len l = if null l then 0 else 1 + len (tl l);;
         (id 1, id true, len [true]);;
         fun f -> (f 1, f true);;",
        &[
            "id : 'a -> 'a",
            "compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b",
            "- : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b",
            "len : 'a list -> int",
            "- : int * bool * int",
            "error: unify",
        ],
    );
}

#[test]
fn spec_example_two() {
    check(
        "let succ n = fun f x -> f (n f x);;
         let add m n = fun f x -> m f (n f x);;
         fun x -> x x;;
         let g = id id;;
         let id = fun x -> x;;
         let g = id id;;
         (g 1, g true);;
         [fun p -> (snd p, fst p)];;",
        &[
            "succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b",
            "add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c",
            "error: occurs",
            "error: unbound",
            "id : 'a -> 'a",
            "g : 'a -> 'a",
            "- : int * bool",
            "- : ('a * 'b -> 'b * 'a) list",
        ],
    );
}

#[test]
fn spec_example_three() {
    check(
        "let map = 3;;
         map;;
         fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;
         let rec bad x = bad 1 + bad true;;
         1 :: [true];;",
        &[
            "map : int",
            "- : int",
            "- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a",
            "error: unify",
            "error: unify",
        ],
    );
}

#[test]
fn builtins() {
    check(
        "not;; fst;; snd;; hd;; tl;; null;; length;; map;; fold;;",
        &[
            "- : bool -> bool",
            "- : 'a * 'b -> 'a",
            "- : 'a * 'b -> 'b",
            "- : 'a list -> 'a",
            "- : 'a list -> 'a list",
            "- : 'a list -> bool",
            "- : 'a list -> int",
            "- : ('a -> 'b) -> 'a list -> 'b list",
            "- : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a",
        ],
    );
}

#[test]
fn error_order_follows_left_to_right_inference() {
    check(
        "fun x -> if true then (x, 0) else ([x], true);;
         true + undefined;;
         undefined + true;;",
        &["error: occurs", "error: unify", "error: unbound"],
    );
}

#[test]
fn fun_body_ends_at_comma_and_semicolon() {
    check(
        "(fun x -> x, 1);;
         [fun x -> x; fun y -> 1];;
         (let y = 1 in y, 2);;",
        &["- : ('a -> 'a) * int", "- : (int -> int) list", "- : int * int"],
    );
}

#[test]
fn tuples_are_flat_and_arity_matters() {
    check(
        "(1, 2, 3);;
         ((1, 2), 3);;
         [(1, 2); (1, 2, 3)];;
         (1, 2, 3) = (1, 2, 3);;",
        &["- : int * int * int", "- : (int * int) * int", "error: unify", "error: unify"],
    );
}

#[test]
fn let_is_not_recursive_and_shadowing_works() {
    check(
        "let x = x + 1;;
         let x = 1;;
         let x = x + 1;;
         x;;
         let not = 1;;
         not;;",
        &["error: unbound", "x : int", "x : int", "- : int", "not : int", "- : int"],
    );
}

#[test]
fn failed_declaration_keeps_previous_binding() {
    check(
        "let x = 1;;
         let x = x true;;
         x;;",
        &["x : int", "error: unify", "- : int"],
    );
}

#[test]
fn no_value_restriction_and_monomorphic_lambda_params() {
    check(
        "let id = fun x -> x;;
         let g = id id;;
         (g 1, g true);;
         fun f -> (f 1, f true);;
         let h = fun f -> let k = f in (k 1, k true);;",
        &["id : 'a -> 'a", "g : 'a -> 'a", "- : int * bool", "error: unify", "error: unify"],
    );
}

#[test]
fn recursion_is_monomorphic_inside_its_body() {
    check(
        "let rec f x = f 1 + f true;;
         let rec map2 f l = if null l then [] else f (hd l) :: map2 f (tl l);;
         map2;;",
        &[
            "error: unify",
            "map2 : ('a -> 'b) -> 'a list -> 'b list",
            "- : ('a -> 'b) -> 'a list -> 'b list",
        ],
    );
}

#[test]
fn operators_are_monomorphic() {
    check(
        "true = false;;
         1 < 2 && 3 >= 4 || false;;
         1 + 2 * 3 - 4 / 5;;
         if 1 < 2 then 1 else 2 + 3;;",
        &["error: unify", "- : bool", "- : int", "- : int"],
    );
}

#[test]
fn cons_and_list_literals() {
    check(
        "[];;
         1 :: 2 :: [];;
         [[1]; []];;
         [1; true];;
         1 :: [true];;",
        &["- : 'a list", "- : int list", "- : int list list", "error: unify", "error: unify"],
    );
}

#[test]
fn type_variable_names_run_past_z() {
    let params: Vec<String> = (0..30).map(|i| format!("x{}", i)).collect();
    let src = format!("fun {} -> ({});;", params.join(" "), params.join(", "));
    let out = run(&src);
    assert!(out.contains("'z -> 'a1 -> 'b1"), "{}", out);
    assert!(out.contains("* 'z * 'a1 * 'b1"), "{}", out);
}

#[test]
fn deep_nesting_does_not_overflow() {
    let n = 4000;
    let src = format!("{}1{};;", "(".repeat(n), ")".repeat(n));
    assert_eq!(run(&src), "- : int\n");
    let src = format!("{}1{};;", "[".repeat(2000), "]".repeat(2000));
    assert_eq!(run(&src), format!("- : int{}\n", " list".repeat(2000)));
}

#[test]
fn shared_types_do_not_explode() {
    // Each step doubles the printed size of the type but not of the graph.
    let mut src = String::from("let d x = (x, x);;\nlet t = ");
    src.push_str(&"d (".repeat(12));
    src.push('1');
    src.push_str(&")".repeat(12));
    src.push_str(";;\n");
    let out = run(&src);
    assert!(out.lines().nth(1).unwrap().len() > 10_000);
}

#[test]
fn session_keeps_environment_between_sources() {
    let mut s = Session::new();
    s.infer_source("let two = 2;;").unwrap();
    let r = s.infer_source("two;;").unwrap();
    assert_eq!(r[0].outcome, Ok("int".to_string()));
    assert_eq!(r[0].name, None);
}

#[test]
fn results_expose_structured_errors() {
    let r = infer_program("x;; fun x -> x x;; 1 2;;").unwrap();
    let kinds: Vec<_> = r.iter().map(|d| d.outcome.clone()).collect();
    assert_eq!(
        kinds,
        vec![Err(TypeError::Unbound), Err(TypeError::Occurs), Err(TypeError::Unify)]
    );
}

#[test]
fn malformed_input_is_a_parse_error() {
    let e: ParseError = infer_program("let = 1;;").unwrap_err();
    assert!(e.to_string().contains("syntax error"));
}
