module test_example;

// The example from the README, kept compiling and passing.
unittest
{
    import textbuffer;

    auto buf = TextBuffer.fromText("alpha\nbeta\ngamma");
    buf.addCursor(1, 0);
    buf.addCursor(2, 0);
    buf.insert("- ");
    assert(buf.text == "- alpha\n- beta\n- gamma");

    buf.move(Direction.end, true);   // select to the end of each line
    buf.insert("X");
    assert(buf.text == "- X\n- X\n- X");

    buf.undo();
    assert(buf.text == "- alpha\n- beta\n- gamma");
    buf.redo();

    CharBuf output;
    buf.render(output);
    assert(output[] == "- X\n- X\n- X\ncursor 0 3\ncursor 1 3\ncursor 2 3\n--\n");
}
