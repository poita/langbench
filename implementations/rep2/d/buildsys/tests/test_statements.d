module test_statements;

import helpers;

unittest
{
    // let / set / scoping
    assert(evalFile("let a = 1\nlet a = 2\n") == "E_REDEFINE a");
    assert(evalFile("let a = 1\nwhen true {\n let a = 2\n}\n") == "");
    assert(evalFile("set a = 1\n") == "E_SET_UNDEFINED a");
    assert(evalFile("let a = undefined\nlet a = 1\n") == "E_UNKNOWN_VAR undefined");
    assert(evalFile("let a = 1\nwhen true {\n set a = 2\n}\nabort str(a)\n") == "E_ABORT 2");
    assert(evalFile("each i, x in [10, 20] {\n}\nabort str(i)\n") == "E_UNKNOWN_VAR i");
    assert(evalFile("each x in 1 {\n}\n") == "E_TYPE each subject: expected list, got int");
    assert(evalFile("when 1 {\n}\n") == "E_TYPE when condition: expected bool, got int");
    assert(evalFile("when false {\n} elsewhen 2 {\n}\n") == "E_TYPE when condition: expected bool, got int");
    assert(evalFile("when true {\n} elsewhen 2 {\n}\n") == "");
}

unittest
{
    // include
    string[string] files = ["a.kiln": "let x = 1\n", "loop.kiln": "include \"loop.kiln\"\n",
        "bad.kiln": "let = 1\n"];
    assert(evalFile("include \"a.kiln\"\nabort str(x)\n", files) == "E_ABORT 1");
    assert(evalFile("include \"a.kiln\"\ninclude \"a.kiln\"\n", files) == "E_REDEFINE x");
    assert(evalFile("include \"nope.kiln\"\n", files) == "E_INCLUDE_MISSING nope.kiln");
    assert(evalFile("include \"loop.kiln\"\n", files) == "E_INCLUDE_CYCLE loop.kiln");
    assert(evalFile("include \"main.kiln\"\n", files) == "E_INCLUDE_CYCLE main.kiln");
    assert(evalFile("include \"../x\"\n", files) == "E_BAD_PATH ../x");
    assert(evalFile("include 3\n", files) == "E_TYPE include path: expected str, got int");
    assert(evalFile("include \"bad.kiln\"\n", files) == "E_PARSE bad.kiln:1");
}

unittest
{
    // rules
    assert(evalFile("rule r(a, b = a ~ \"!\") {\n abort b\n}\nuse r(\"x\")\n") == "E_ABORT x!");
    assert(evalFile("rule r(a) {\n}\nuse r()\n") == "E_ARG rule r: missing argument a");
    assert(evalFile("rule r(a) {\n}\nuse r(1, 2)\n") == "E_ARITY rule r: expected 1, got 2");
    assert(evalFile("rule r(a) {\n}\nuse r(b = 1)\n") == "E_ARG rule r: unknown argument b");
    assert(evalFile("rule r(a) {\n}\nuse r(1, a = 2)\n") == "E_ARG rule r: duplicate argument a");
    assert(evalFile("use nope(undefined)\n") == "E_UNKNOWN_RULE nope");
    assert(evalFile("rule r() {\n}\nrule r() {\n}\n") == "E_REDEFINE r");
    assert(evalFile("rule r() {\n use r()\n}\nuse r()\n") == "E_RULE_RECURSION r");
    // rule scope is the defining scope, by reference
    assert(evalFile("let k = 1\nrule r() {\n abort str(k)\n}\nset k = 5\nwhen true {\n let k = 9\n use r()\n}\n") == "E_ABORT 5");
}

unittest
{
    // abort, default, phony
    assert(evalFile("abort 3\n") == "E_TYPE abort message: expected str, got int");
    assert(evalFile("abort \"n={1+1}\"\n") == "E_ABORT n=2");
    assert(evalFile("default [1]\n") == "E_TYPE default: expected strlist, got int");
    assert(evalFile("phony a = []\nphony a = []\n") == "E_DUP_PHONY a");
    assert(evalFile("phony a = 3\n") == "E_TYPE phony a: expected strlist, got int");
    assert(evalFile("phony a = [\"bad path\"]\n") == "E_BAD_PATH bad path");
    assert(evalFile("phony a = [\"@1x\"]\n") == "E_BAD_PATH @1x");
    assert(evalFile("phony a = [\"@b\"]\n") == "");
}

unittest
{
    // step field handling and validation order
    enum pre = "step {\n";
    assert(evalFile(pre ~ "cmd write(\"x\")\n}\n") == "E_STEP_FIELD missing out");
    assert(evalFile(pre ~ "out \"out/a\"\n}\n") == "E_STEP_FIELD missing cmd");
    assert(evalFile(pre ~ "out \"out/a\"\ncmd write(\"x\")\ncmd write(\"y\")\n}\n") == "E_STEP_FIELD duplicate cmd");
    assert(evalFile(pre ~ "cost 1\ncost undefined\n}\n") == "E_STEP_FIELD duplicate cost");
    assert(evalFile(pre ~ "depfile \"a\"\ndepfile \"b\"\n}\n") == "E_STEP_FIELD duplicate depfile");
    assert(evalFile(pre ~ "cost -1\n}\n") == "E_ARG field cost: negative");
    assert(evalFile(pre ~ "cost \"a\"\n}\n") == "E_TYPE field cost: expected int, got str");
    assert(evalFile(pre ~ "out 1\n}\n") == "E_TYPE field out: expected strlist, got int");
    assert(evalFile(pre ~ "out [\"a\", 1]\n}\n") == "E_TYPE field out: expected strlist, got int");
    assert(evalFile(pre ~ "out \"src/a\"\ncmd write(\"x\")\n}\n") == "E_OUTPUT_PATH src/a");
    assert(evalFile(pre ~ "out \"out/a b\"\ncmd write(\"x\")\n}\n") == "E_BAD_PATH out/a b");
    assert(evalFile(pre ~ "out \"out/a\"\nin \"@\"\ncmd write(\"x\")\n}\n") == "E_BAD_PATH @");
    assert(evalFile(pre ~ "out \"out/a\"\ncmd nope()\n}\n") == "E_UNKNOWN_CMD nope");
    assert(evalFile(pre ~ "out \"out/a\"\ncmd grep()\n}\n") == "E_ARITY cmd grep: expected 1, got 0");
    assert(evalFile(pre ~ "out \"out/a\"\ncmd indent(\"x\")\n}\n") == "E_TYPE cmd indent argument 1: expected int, got str");
    assert(evalFile(pre ~ "out \"out/a\"\nin \"x\"\ncmd write(\"x\")\n}\n", ["x": ""]) == "E_CMD_SHAPE write: expected inputs 0-0, got 1");
    assert(evalFile(pre ~ "out \"out/a\"\ncmd copy()\n}\n") == "E_CMD_SHAPE copy: expected inputs 1-1, got 0");
    assert(evalFile(pre ~ "out \"out/a\"\ncmd concat()\n}\n") == "E_CMD_SHAPE concat: expected inputs 1-N, got 0");
    assert(evalFile(pre ~ "out [\"out/a\", \"out/b\"]\ncmd write(\"\")\n}\n") == "E_CMD_SHAPE write: expected outputs 1, got 2");
    assert(evalFile(pre ~ "out \"out/a\"\ncmd preprocess()\nin \"x\"\n}\n", ["x": ""]) == "E_CMD_SHAPE preprocess: depfile required");
    assert(evalFile(pre ~ "out \"out/a\"\ndepfile \"out/d\"\ncmd write(\"\")\n}\n") == "E_CMD_SHAPE write: depfile not allowed");
    assert(evalFile(pre ~ "out \"out/a\"\nin \"x\"\ncmd replace(\"\", \"y\")\n}\n", ["x": ""]) == "E_ARG cmd replace: empty pattern");
    assert(evalFile(pre ~ "out \"out/a\"\nin \"x\"\ncmd indent(-1)\n}\n", ["x": ""]) == "E_ARG cmd indent: negative");
    assert(evalFile(pre ~ "out \"out/a\"\nin [\"@p\", \"x\"]\ncmd copy()\n}\n", ["x": ""]) == "");
}
