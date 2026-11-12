//! Integration tests for the public API: the examples from the specification
//! plus edge cases around empty cells, cycles, errors and incremental edits.

use spreadsheet::{run_script, CellRef, Content, Error, ErrorCode, Sheet, Value};

fn script(input: &str) -> String {
    let mut out = Vec::new();
    let errors = run_script(input, &mut out).unwrap();
    assert!(errors.is_empty(), "{errors:?}");
    String::from_utf8(out).unwrap()
}

/// Sets `A1` to a formula and returns its displayed value.
fn eval(formula: &str) -> String {
    let mut s = Sheet::new();
    s.set_content("A1", &format!("={formula}")).unwrap();
    s.display("A1").unwrap()
}

#[test]
fn spec_example_cycle_created_and_broken() {
    let out = script(
        "set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\nget A3\nset A1 5\nget A3\ndump",
    );
    assert_eq!(out, "42\n#CYCLE!\n#CYCLE!\n37\nA1 5\nA2 32\nA3 37\n");
}

#[test]
fn spec_example_strings_ranges_if_errors() {
    let out = script(
        "set A1 \"Total\"\nset B1 3\nset B2 4.5\nset B3 \"x\"\nset C1 =SUM(B1:B3)\n\
         set C2 =A1&\": \"&C1\nset C3 =IF(C1>7, \"big\", \"small\")\nset C4 =AVG(B1:B3)\n\
         set C5 =COUNT(B1:B3)\nset C6 =B1/(B2-4.5)\nset C7 =C6+1\nset C8 =1/3\ndump",
    );
    assert_eq!(
        out,
        "A1 Total\nB1 3\nC1 7.5\nB2 4.5\nC2 Total: 7.5\nB3 x\nC3 big\nC4 3.75\nC5 2\n\
         C6 #DIV/0!\nC7 #DIV/0!\nC8 0.3333333333\n"
    );
}

#[test]
fn spec_example_precedence_and_clear() {
    let out = script(
        "set A1 =1+2*3\nset A2 =(1+2)*3\nset A3 =-2*3-4\nset A4 =2*-3\nset A5 =1<2+3\nset A6 =1+2&3\n\
         set A7 =100000000000000000000\nset A8 =0.00001\nset A9 =1234567.891\nset A10 =2/3*3\n\
         set B1 =A9\nclear A9\nget B1\ndump",
    );
    assert_eq!(out, "0\nA1 7\nB1 0\nA2 9\nA3 -10\nA4 -6\nA5 1\nA6 33\nA7 1e+20\nA8 1e-05\nA10 2\n");
}

#[test]
fn precedence_and_unary_minus() {
    assert_eq!(eval("1+2*3"), "7");
    assert_eq!(eval("-2*3-4"), "-10");
    assert_eq!(eval("--5"), "5");
    assert_eq!(eval("1+2&3"), "33");
    assert_eq!(eval("10-2-3"), "5");
    assert_eq!(eval("8/2/2"), "2");
}

#[test]
fn empty_cell_rules() {
    assert_eq!(eval("(Z1)&\"x\""), "x");
    assert_eq!(eval("IF(1,Z1,7)&\"x\""), "x");
    assert_eq!(eval("(Z1)=\"\""), "1");
    assert_eq!(eval("Z1=0"), "1");
    assert_eq!(eval("COUNT((Z1))"), "0");
    assert_eq!(eval("-Z1&\"x\""), "0x");
    assert_eq!(eval("Z1"), "0");
    assert_eq!(eval("Z1+1"), "1");
    assert_eq!(eval("Z1<\"a\""), "1");
}

#[test]
fn errors_and_their_order() {
    assert_eq!(eval("\"5\"+1"), "#VALUE!");
    assert_eq!(eval("1/0"), "#DIV/0!");
    assert_eq!(eval("\"a\"+1/0"), "#VALUE!");
    assert_eq!(eval("1/0+\"a\""), "#DIV/0!");
    assert_eq!(eval("999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999"), "#VALUE!");
}

#[test]
fn comparisons() {
    assert_eq!(eval("1=\"1\""), "0");
    assert_eq!(eval("1<>\"1\""), "1");
    assert_eq!(eval("1<\"1\""), "#VALUE!");
    assert_eq!(eval("\"a\"<\"b\""), "1");
    assert_eq!(eval("\"a\"<\"A\""), "0");
    assert_eq!(eval("\"ab\">\"a\""), "1");
    assert_eq!(eval("\"\u{1F600}\">\"\u{FF5A}\""), "1");
    assert_eq!(eval("2>=2"), "1");
    assert_eq!(eval("2<=1"), "0");
}

#[test]
fn if_evaluates_only_selected_branch() {
    assert_eq!(eval("IF(1,5,1/0)"), "5");
    assert_eq!(eval("IF(0,1/0,6)"), "6");
    assert_eq!(eval("IF(\"a\",1,2)"), "#VALUE!");
    assert_eq!(eval("IF(0,1,\"no\")"), "no");
}

#[test]
fn aggregates() {
    let mut s = Sheet::new();
    for (c, v) in [("A1", "1"), ("A2", "\"x\""), ("A3", "5"), ("B1", "-2")] {
        s.set_content(c, v).unwrap();
    }
    for (f, want) in [
        ("SUM(A1:A3)", "6"),
        ("SUM(A1:B3)", "4"),
        ("MIN(B1:A3)", "-2"),
        ("MAX(A1:A3, 10)", "10"),
        ("AVG(A1:A3)", "3"),
        ("COUNT(A1:B3, 7)", "4"),
        ("SUM(C1:C3)", "0"),
        ("MIN(C1:C3)", "0"),
        ("AVG(C1:C3)", "#DIV/0!"),
        ("SUM(\"x\")", "#VALUE!"),
        ("SUM(A1:A3, Z9)", "6"),
    ] {
        s.set_content("D1", &format!("={f}")).unwrap();
        assert_eq!(s.display("D1").unwrap(), want, "{f}");
    }
}

#[test]
fn invalid_references_give_ref_error_and_no_dependencies() {
    let mut s = Sheet::new();
    s.set_content("A1", "=AAA1+1").unwrap();
    s.set_content("A2", "=IF(1,5,A0)").unwrap();
    s.set_content("A3", "=SUM(A1:A10000)").unwrap();
    for c in ["A1", "A2", "A3"] {
        assert_eq!(s.display(c).unwrap(), "#REF!");
    }
    // Having no dependencies, a self-looking invalid formula is not a cycle.
    s.set_content("B1", "=B1+A01").unwrap();
    assert_eq!(s.display("B1").unwrap(), "#REF!");
}

#[test]
fn cycles() {
    let mut s = Sheet::new();
    s.set_content("A1", "=A1+1").unwrap();
    assert_eq!(s.display("A1").unwrap(), "#CYCLE!");
    s.set_content("A1", "=SUM(A1:A3)").unwrap();
    assert_eq!(s.display("A1").unwrap(), "#CYCLE!");
    s.set_content("A2", "=A1").unwrap();
    s.set_content("A3", "=IF(1,7,A2)").unwrap(); // reads A2, so it is in the cycle via the range
    assert_eq!(s.display("A3").unwrap(), "#CYCLE!");
    s.set_content("B1", "=IF(1,7,A1)").unwrap(); // not cyclic itself; selected branch avoids the error
    assert_eq!(s.display("B1").unwrap(), "7");
    s.set_content("B2", "=A1+1").unwrap();
    assert_eq!(s.display("B2").unwrap(), "#CYCLE!");
    s.clear("A1".parse_cell());
    assert_eq!(s.display("A2").unwrap(), "0");
    assert_eq!(s.display("A3").unwrap(), "7");
    assert_eq!(s.display("B2").unwrap(), "1");
}

trait ParseCell {
    fn parse_cell(&self) -> CellRef;
}
impl ParseCell for str {
    fn parse_cell(&self) -> CellRef {
        CellRef::parse(self).unwrap()
    }
}

#[test]
fn changes_propagate_through_chains_and_diamonds() {
    let mut s = Sheet::new();
    s.set_content("A1", "1").unwrap();
    s.set_content("B1", "=A1+1").unwrap();
    s.set_content("C1", "=A1*10").unwrap();
    s.set_content("D1", "=B1+C1").unwrap();
    assert_eq!(s.display("D1").unwrap(), "12");
    s.set_content("A1", "2").unwrap();
    assert_eq!(s.display("D1").unwrap(), "23");
    s.set_content("B1", "\"s\"").unwrap();
    assert_eq!(s.display("D1").unwrap(), "#VALUE!");
    s.clear("B1".parse_cell());
    assert_eq!(s.display("D1").unwrap(), "20");
}

#[test]
fn rewriting_a_formula_drops_old_dependencies() {
    let mut s = Sheet::new();
    s.set_content("A1", "1").unwrap();
    s.set_content("B1", "5").unwrap();
    s.set_content("C1", "=A1").unwrap();
    s.set_content("C1", "=B1").unwrap();
    s.set_content("A1", "100").unwrap();
    assert_eq!(s.display("C1").unwrap(), "5");
    s.set_content("B1", "6").unwrap();
    assert_eq!(s.display("C1").unwrap(), "6");
}

#[test]
fn dump_is_row_major_and_includes_empty_strings() {
    let mut s = Sheet::new();
    s.set_content("B2", "1").unwrap();
    s.set_content("AA1", "\"\"").unwrap();
    s.set_content("A2", "2").unwrap();
    s.set_content("Z1", "3").unwrap();
    s.set_content("C3", "4").unwrap();
    s.clear("C3".parse_cell());
    let names: Vec<String> = s.dump().into_iter().map(|(c, _)| c.to_string()).collect();
    assert_eq!(names, ["Z1", "AA1", "A2", "B2"]);
}

#[test]
fn content_parsing() {
    assert_eq!(Content::parse("-0").unwrap(), Content::Number(0.0));
    assert_eq!(Content::parse("007").unwrap(), Content::Number(7.0));
    assert!(matches!(Content::parse("\"\"").unwrap(), Content::Text(t) if t.is_empty()));
    assert!(Content::parse("1.").is_err());
    assert!(Content::parse("\"abc").is_err());
    assert!(matches!(Content::parse("=1+"), Err(Error::Formula(_))));
}

#[test]
fn get_on_empty_cell_is_empty() {
    let s = Sheet::new();
    assert_eq!(s.get("A1".parse_cell()), Value::Empty);
    assert_eq!(script("get A1\n"), "\n");
    assert_eq!(script(""), "");
}

#[test]
fn long_dependency_chain() {
    let mut s = Sheet::new();
    s.set_content("A1", "1").unwrap();
    for row in 2..=9999 {
        s.set_content(&format!("A{row}"), &format!("=A{}+1", row - 1)).unwrap();
    }
    assert_eq!(s.display("A9999").unwrap(), "9999");
    s.set_content("A1", "11").unwrap();
    assert_eq!(s.display("A9999").unwrap(), "10009");
    s.set_content("A1", "=A9999").unwrap();
    assert_eq!(s.get("A5000".parse_cell()), Value::Error(ErrorCode::Cycle));
}

#[test]
fn large_range_resums_after_edit() {
    let mut s = Sheet::new();
    for row in 1..=9999 {
        s.set_content(&format!("A{row}"), "1").unwrap();
    }
    s.set_content("B1", "=SUM(A1:A9999)").unwrap();
    assert_eq!(s.display("B1").unwrap(), "9999");
    s.set_content("A5000", "=B1").unwrap();
    assert_eq!(s.display("B1").unwrap(), "#CYCLE!");
    s.set_content("A5000", "2").unwrap();
    assert_eq!(s.display("B1").unwrap(), "10000");
}
