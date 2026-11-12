//! The worked examples of the specification, run through the script runner.

use textbuffer::script;

fn run(input: &str) -> String {
    let mut out = Vec::new();
    script::run(input.as_bytes(), &mut out).expect("script runs");
    String::from_utf8(out).unwrap()
}

#[test]
fn example_1_single_cursor() {
    let input = "2\nhello world\nsecond line\nmove end\ninsert !\nmove down\ninsert  (edited)\n\
                 goto 0 5\ninsert ,\nprint\ndelete\ndelete\nprint\n";
    assert_eq!(
        run(input),
        "hello, world!\nsecond line (edited)\ncursor 0 6\n--\n\
         hell world!\nsecond line (edited)\ncursor 0 4\n--\n"
    );
}

#[test]
fn example_2_multiple_cursors_and_selections() {
    let input = "3\nalpha\nbeta\ngamma\nadd-cursor 1 0\nadd-cursor 2 0\ninsert - \nprint\n\
                 move end select\ninsert X\nprint\ngoto 0 1\nmove right select\n\
                 move right select\ndelete\nprint\n";
    assert_eq!(
        run(input),
        "- alpha\n- beta\n- gamma\ncursor 0 2\ncursor 1 2\ncursor 2 2\n--\n\
         - X\n- X\n- X\ncursor 0 3\ncursor 1 3\ncursor 2 3\n--\n\
         -\n- X\n- X\ncursor 0 1\n--\n"
    );
}

#[test]
fn example_3_undo_and_redo() {
    let input = "1\nabc\nmove end\ninsert d\\ne\nprint\ndelete\ndelete\nprint\nundo\nprint\n\
                 undo\nprint\nredo\nprint\ninsert Z\nredo\nprint\n";
    assert_eq!(
        run(input),
        "abcd\ne\ncursor 1 1\n--\nabcd\ncursor 0 4\n--\nabcd\n\ncursor 1 0\n--\n\
         abcd\ne\ncursor 1 1\n--\nabcd\n\ncursor 1 0\n--\nabcd\nZ\ncursor 1 1\n--\n"
    );
}
