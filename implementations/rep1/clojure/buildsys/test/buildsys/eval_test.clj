(ns buildsys.eval-test
  (:require [buildsys.test-util :refer [build-error eval-expr]]
            [clojure.test :refer [deftest is testing]]))

(deftest arithmetic
  (is (= "7" (eval-expr "1 + 2 * 3")))
  (is (= "-3" (eval-expr "-7 / 2")) "division truncates toward zero")
  (is (= "-1" (eval-expr "-7 % 2")) "modulo has the sign of the dividend")
  (is (= "1" (eval-expr "7 % -2")))
  (is (= "E_DIV_ZERO" (eval-expr "1 / 0")))
  (is (= "E_DIV_ZERO" (eval-expr "1 % (2 - 2)"))))

(deftest operators
  (is (= "ab" (eval-expr "\"a\" ~ \"b\"")))
  (is (= "true" (eval-expr "[1] ++ [2] == [1, 2]")))
  (is (= "true" (eval-expr "1 < \"a\" && \"a\" < [] && false < true")))
  (is (= "true" (eval-expr "[1, 2] < [1, 3] && [1] < [1, 0]")))
  (is (= "false" (eval-expr "1 == true")))
  (is (= "true" (eval-expr "true || undefined_var")) "|| short-circuits")
  (is (= "false" (eval-expr "false && undefined_var")) "&& short-circuits")
  (is (= "E_TYPE operator &&: expected bool, got int" (eval-expr "true && 1")))
  (is (= "E_TYPE operator +: expected int, got str" (eval-expr "\"a\" + [1]")))
  (is (= "E_TYPE operator -: expected int, got bool" (eval-expr "-true")))
  (is (= "E_TYPE operator !: expected bool, got int" (eval-expr "!1")))
  (is (= "E_TYPE operator ++: expected list, got int" (eval-expr "[] ++ 1"))))

(deftest indexing
  (is (= "c" (eval-expr "\"abc\"[2]")))
  (is (= "c" (eval-expr "\"abc\"[-1]")))
  (is (= "2" (eval-expr "[1, 2][1]")))
  (is (= "E_ARG fn index: out of range" (eval-expr "[1][1]")))
  (is (= "E_ARG fn index: out of range" (eval-expr "[1][-2]")))
  (is (= "E_TYPE index: expected int, got str" (eval-expr "5[\"a\"]")))
  (is (= "E_TYPE index target: expected str|list, got int" (eval-expr "5[0]"))))

(deftest interpolation
  (is (= "x7" (eval-expr "let n = 7" "\"x{n}\"")))
  (is (= "15" (eval-expr "let n = 7" "\"{n * 2 + 1}\"")))
  (is (= "{lit}" (eval-expr "\"{{lit}}\"")))
  (is (= "a, b" (eval-expr "let xs = [\"a\", \"b\"]" "\"{join(xs, \", \")}\"")))
  (is (= "E_INTERP list" (eval-expr "\"{[1]}\"")))
  (is (= "true" (eval-expr "\"{1 == 1}\""))))

(deftest scoping
  (is (= "E_REDEFINE x" (build-error {"main.kiln" "let x = 1\nlet x = 2\n"})))
  (is (= "E_SET_UNDEFINED y" (build-error {"main.kiln" "set y = 1\n"})))
  (is (= "E_UNKNOWN_VAR q" (build-error {"main.kiln" "let x = 1 + q\nlet x = 2\n"}))
      "the expression is evaluated before the redefinition check")
  (is (= "E_ABORT 2"
         (build-error {"main.kiln" "let x = 1\nwhen true {\n let x = 2\n abort str(x)\n}\n"}))
      "shadowing in a child scope is allowed")
  (is (= "E_ABORT 5"
         (build-error {"main.kiln" "let x = 1\neach i in [1, 2] {\n set x = x + 2\n}\nabort str(x)\n"}))
      "set updates the innermost scope that binds the name"))

(deftest includes
  (is (= "E_INCLUDE_MISSING nope.kiln" (build-error {"main.kiln" "include \"nope.kiln\"\n"})))
  (is (= "E_INCLUDE_CYCLE a.kiln"
         (build-error {"main.kiln" "include \"a.kiln\"\n" "a.kiln" "include \"a.kiln\"\n"})))
  (is (= "E_REDEFINE x"
         (build-error {"main.kiln" "include \"a.kiln\"\ninclude \"a.kiln\"\n" "a.kiln" "let x = 1\n"})))
  (is (= "E_BAD_PATH ../x"
         (build-error {"main.kiln" "include \"../x\"\n"})))
  (is (= "E_PARSE a.kiln:2"
         (build-error {"main.kiln" "let y = 1\ninclude \"a.kiln\"\n" "a.kiln" "let x = 1\nlet\n"}))
      "an included file is parsed in full at the point of the include")
  (is (= "E_ABORT 1"
         (build-error {"main.kiln" "include \"a.kiln\"\nabort str(extra)\n" "a.kiln" "let extra = 1\n"}))
      "an include runs in the including scope"))

(deftest rules
  (let [rule "rule r(a, b = a ~ \"!\") {\n abort a ~ b\n}\n"]
    (is (= "E_ABORT xx!" (build-error {"main.kiln" (str rule "use r(\"x\")\n")})))
    (is (= "E_ABORT xy" (build-error {"main.kiln" (str rule "use r(\"x\", b = \"y\")\n")})))
    (is (= "E_ARITY rule r: expected 2, got 3" (build-error {"main.kiln" (str rule "use r(1, 2, 3)\n")})))
    (is (= "E_ARG rule r: unknown argument z" (build-error {"main.kiln" (str rule "use r(1, z = 2)\n")})))
    (is (= "E_ARG rule r: duplicate argument a" (build-error {"main.kiln" (str rule "use r(1, a = 2)\n")})))
    (is (= "E_ARG rule r: missing argument a" (build-error {"main.kiln" (str rule "use r(b = 2)\n")})))
    (is (= "E_UNKNOWN_RULE nope" (build-error {"main.kiln" "use nope(undefined)\n"}))
        "the rule is looked up before any argument is evaluated")
    (is (= "E_REDEFINE r" (build-error {"main.kiln" (str rule rule)}))))
  (testing "recursion depth is limited to 64"
    (let [src (fn [n] (str "rule r(n) {\n when n > 0 {\n  use r(n - 1)\n }\n}\nuse r(" n ")\nabort \"done\"\n"))]
      (is (= "E_ABORT done" (build-error {"main.kiln" (src 63)})))
      (is (= "E_RULE_RECURSION r" (build-error {"main.kiln" (src 64)}))))))

(deftest rule-scope-is-the-defining-scope
  (is (= "E_ABORT 10"
         (build-error
          {"main.kiln" (str "let base = 1\nrule r() {\n abort str(base)\n}\n"
                            "set base = 10\nwhen true {\n let base = 99\n use r()\n}\n")}))))

(deftest steps
  (let [step (fn [& fields] {"main.kiln" (str "step {\n" (apply str (map #(str " " % "\n") fields)) "}\n")})]
    (is (= "E_STEP_FIELD missing cmd" (build-error (step "out \"out/a\""))))
    (is (= "E_STEP_FIELD missing out" (build-error (step "cmd write(\"x\")"))))
    (is (= "E_STEP_FIELD duplicate cost" (build-error (step "out \"out/a\"" "cmd write(\"x\")" "cost 1" "cost undefined"))))
    (is (= "E_STEP_FIELD duplicate cmd" (build-error (step "out \"out/a\"" "cmd write(\"x\")" "cmd write(\"y\")"))))
    (is (= "E_ARG field cost: negative" (build-error (step "out \"out/a\"" "cost -1" "cmd write(\"x\")"))))
    (is (= "E_UNKNOWN_CMD frob" (build-error (step "out \"out/a\"" "cmd frob(undefined)"))))
    (is (= "E_ARITY cmd grep: expected 1, got 0" (build-error (step "out \"out/a\"" "in \"main.kiln\"" "cmd grep()"))))
    (is (= "E_TYPE cmd indent argument 1: expected int, got str"
           (build-error (step "out \"out/a\"" "in \"main.kiln\"" "cmd indent(\"x\")"))))
    (is (= "E_OUTPUT_PATH src/a" (build-error (step "out \"src/a\"" "cmd write(\"x\")"))))
    (is (= "E_BAD_PATH out/../a" (build-error (step "out \"out/../a\"" "cmd write(\"x\")"))))
    (is (= "E_BAD_PATH @1x" (build-error (step "out \"out/a\"" "in \"@1x\"" "cmd write(\"x\")"))))
    (is (= "E_CMD_SHAPE write: expected inputs 0-0, got 1"
           (build-error (step "out \"out/a\"" "in \"main.kiln\"" "cmd write(\"x\")"))))
    (is (= "E_CMD_SHAPE copy: expected outputs 1, got 2"
           (build-error (step "out [\"out/a\", \"out/b\"]" "in \"main.kiln\"" "cmd copy()"))))
    (is (= "E_CMD_SHAPE copy: depfile not allowed"
           (build-error (step "out \"out/a\"" "depfile \"out/d\"" "in \"main.kiln\"" "cmd copy()"))))
    (is (= "E_CMD_SHAPE preprocess: depfile required"
           (build-error (step "out \"out/a\"" "in \"main.kiln\"" "cmd preprocess()"))))
    (is (= "E_ARG cmd replace: empty pattern"
           (build-error (step "out \"out/a\"" "in \"main.kiln\"" "cmd replace(\"\", \"x\")"))))
    (is (= "E_TYPE field out: expected strlist, got int" (build-error (step "out 1" "cmd write(\"x\")"))))
    (is (= "E_TYPE field in: expected strlist, got bool"
           (build-error (step "out \"out/a\"" "in [\"a\", true]" "cmd write(\"x\")"))))))
