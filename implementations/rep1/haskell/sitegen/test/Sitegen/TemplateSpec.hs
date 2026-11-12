{-# LANGUAGE OverloadedStrings #-}

module Sitegen.TemplateSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Sitegen.Template

-- | Render the template "main" among the given ones.
run :: [(Text, Text)] -> [(Text, Value)] -> Either ErrorKind Text
run tpls = renderTemplate (mkTemplates (("main", main') : others)) "main"
  where
    main' = maybe "" id (lookup "main" tpls)
    others = filter ((/= "main") . fst) tpls

r :: Text -> Either ErrorKind Text
r src = run [("main", src)] []

rc :: Text -> [(Text, Value)] -> Either ErrorKind Text
rc src = run [("main", src)]

ok :: Text -> Text -> Expectation
ok src out = r src `shouldBe` Right out

err :: Text -> ErrorKind -> Expectation
err src k = r src `shouldBe` Left k

str :: Text -> Value
str = VString

spec :: Spec
spec = do
  describe "text and whitespace control" $ do
    it "copies text and treats stray braces as text" $
      ok "a { b } {x} c" "a { b } {x} c"
    it "drops comments" $ ok "a{# hi #}b" "ab"
    it "trims around tags with -" $ do
      ok "a  {{- 1 -}}  b" "a1b"
      ok "a \n {%- if true -%} \n x \n {%- endif -%} \n b" "axb"
      ok "a  {#- c -#}  b" "ab"
    it "does not trim across other tags" $
      ok "a {{ 1 }} {{- 2 }}" "a 12"
    it "keeps ordinary newlines after tags (no trim_blocks)" $
      ok "{% if true %}\nx\n{% endif %}\n" "\nx\n\n"
    it "does not end a tag at a closer inside a string" $
      ok "{{ \"%}}\" }}" "%}}"
    it "lets -}} end a tag but not x - }}" $ do
      ok "{{ 3 -}} a" "3a"
      err "{{ 3 - }}" SyntaxError

  describe "expressions" $ do
    it "does arithmetic with exact integers and floats" $ do
      ok "{{ 1 + 2 * 3 }}" "7"
      ok "{{ 7 / 2 }} {{ 7 // 2 }} {{ -7 // 2 }} {{ 7.0 // 2 }} {{ 6 / 3 }}" "3.5 3 -4 3.0 2.0"
      ok "{{ -7 % 3 }} {{ 7 % -3 }} {{ 7.5 % 2 }}" "2 -2 1.5"
      ok "{{ 2 ** 10 }} {{ 2 ** -1 }} {{ -2 ** 2 }} {{ 2 ** 3 ** 2 }}" "1024 0.5 4 64"
    it "binds ~ tighter than + and filters tighter than *" $ do
      ok "{{ 1 ~ 2 * 3 }}" "16"
      err "{{ 1 + 2 ~ 3 }}" TypeError
      ok "{{ 2 * \"3\"|int }}" "6"
      ok "{{ -2.7|int }}" "-2"
    it "prints floats like Python" $
      ok "{{ 0.1 + 0.2 }} {{ 1000000000000000.0 }} {{ 10000000000000000.0 }} {{ 0.0001 }} {{ 0.00001 }} {{ 1.5 * 0 }}"
         "0.30000000000000004 1000000000000000.0 1e+16 0.0001 1e-05 0.0"
    it "prints booleans, none and lists" $
      ok "{{ true }} {{ none }} {{ [1, 'a', true, none, 1.5, \"it's\"] }}"
         "True None [1, 'a', True, None, 1.5, \"it's\"]"
    it "short-circuits and/or and returns the deciding operand" $ do
      ok "{{ 0 or \"x\" }}|{{ \"\" and 1 }}|{{ 1 and 2 }}" "x||2"
      ok "{{ true or missing }}" "True"
    it "chains comparisons" $ do
      ok "{{ 1 < 2 < 3 }} {{ 1 < 3 < 2 }} {{ 1 == 1.0 }} {{ true == 1 }}" "True False True True"
      ok "{{ 1 > 2 > missing }}" "False"
    it "compares across kinds without errors for ==" $
      ok "{{ 1 == \"1\" }} {{ none == 0 }} {{ [1, 2] == [1, 2.0] }}" "False False True"
    it "supports in and not in" $
      ok "{{ \"b\" in \"abc\" }} {{ 2 in [1, 2] }} {{ \"a\" not in \"abc\" }} {{ \"\" in \"x\" }}"
         "True True False True"
    it "repeats and concatenates" $
      ok "{{ \"ab\" * 3 }}{{ 2 * \"-\" }}{{ \"x\" * -1 }}|{{ [1] + [2] }}|{{ \"a\" ~ 1 ~ true }}" "ababab--|[1, 2]|a1True"
    it "accesses dicts, lists and strings" $
      rc "{{ d.a }} {{ d[\"b\"] }} {{ l[0] }} {{ l[-1] }} {{ \"xyz\"[1] }} {{ l[5] is defined }}"
         [ ("d", mkDict [("a", VInt 1), ("b", str "two")]), ("l", mkList [VInt 10, VInt 20]) ]
        `shouldBe` Right "1 two 10 20 y False"
    it "treats booleans as integers for indexing" $
      rc "{{ l[true] }}" [("l", mkList [VInt 10, VInt 20])] `shouldBe` Right "20"

  describe "filters" $ do
    it "converts case and trims" $
      ok "{{ \"aBc\"|upper }}{{ \"aBc\"|lower }}[{{ \" \\t x \"|trim }}]" "ABCabc[x]"
    it "escapes HTML" $
      ok "{{ \"<a href='x'>&\\\"</a>\"|escape }}" "&lt;a href=&#39;x&#39;&gt;&amp;&#34;&lt;/a&gt;"
    it "replaces" $ ok "{{ \"aaa\"|replace(\"aa\", \"b\") }}" "ba"
    it "measures length" $
      rc "{{ \"héé\"|length }} {{ l|length }} {{ d|length }}"
         [("l", mkList [VInt 1, VInt 2]), ("d", mkDict [("k", VNone)])]
        `shouldBe` Right "3 2 1"
    it "converts with int" $
      ok "{{ \"12\"|int }} {{ \" -3 \"|int }} {{ \"3.9\"|int }} {{ \"-3.9\"|int }} {{ \"1e2\"|int }} {{ \"x\"|int }} {{ 2.7|int }} {{ true|int }} {{ none|int }}"
         "12 -3 3 -3 100 0 2 1 0"
    it "joins, reverses and sorts" $
      rc "{{ l|join(\", \") }}|{{ l|join }}|{{ l|reverse|join(\"-\") }}|{{ \"abc\"|reverse }}|{{ m|sort|join(\" \") }}|{{ s|sort|join(\" \") }}"
         [ ("l", mkList [VInt 1, VInt 2, VInt 3])
         , ("m", mkList [VInt 3, VFloat 1.5, VInt 2])
         , ("s", mkList [str "b", str "A", str "a", str "B"]) ]
        `shouldBe` Right "1, 2, 3|123|3-2-1|cba|1.5 2 3|A a b B"
    it "takes first and last of the sequence view" $
      rc "{{ l|first }}{{ l|last }}{{ \"xyz\"|first }}{{ d|last }}{{ e|first is defined }}"
         [ ("l", mkList [VInt 1, VInt 2]), ("d", mkDict [("p", VInt 1), ("q", VInt 2)]), ("e", mkList []) ]
        `shouldBe` Right "12xqFalse"
    it "applies default only to undefined values" $
      ok "{{ missing|default(\"d\") }}{{ \"\"|default(\"d\") }}{{ missing|default }}|" "d|"
    it "chains" $ ok "{{ \"  hi \"|trim|upper }}" "HI"
    it "reports unknown filters when the template is loaded" $ do
      err "{{ 1|nope }}" FilterError
      err "x{% if false %}{{ 1|nope }}{% endif %}" FilterError
    it "reports a wrong number of filter arguments as a type error" $
      err "{{ 1|upper(1) }}" TypeError

  describe "statements" $ do
    it "runs if/elif/else" $
      ok "{% if 0 %}a{% elif \"\" %}b{% elif [1] %}c{% else %}d{% endif %}" "c"
    it "loops with loop variables and else" $ do
      ok "{% for x in [3, 4] %}{{ loop.index }}{{ loop.index0 }}{{ loop.first }}{{ loop.last }}{{ loop.length }}{{ x }};{% endfor %}"
         "10TrueFalse23;21FalseTrue24;"
      ok "{% for x in [] %}a{% else %}none{% endfor %}" "none"
      ok "{% for c in \"ab\" %}{{ c }}-{% endfor %}" "a-b-"
    it "keeps set inside a loop body local to the iteration" $
      ok "{% set x = 1 %}{% for i in [1, 2] %}{% set x = i %}{{ x }}{% endfor %}{{ x }}" "121"
    it "supports range" $ do
      ok "{% for i in range(3) %}{{ i }}{% endfor %}|{{ range(2, 5)|join(\",\") }}|{{ range(5, 0, -2)|join(\",\") }}" "012|2,3,4|5,3,1"
      err "{{ range(1, 2, 0) }}" TypeError
      err "{{ range() }}" TypeError
    it "defines and calls macros with defaults and keywords" $ do
      ok "{% macro m(a, b=a ~ \"!\") %}[{{ a }}{{ b }}]{% endmacro %}{{ m(1) }}{{ m(1, 2) }}{{ m(b=3, a=4) }}" "[11!][12][43]"
      ok "{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}{{ f(5) }}" "120"
    it "rejects bad macro calls" $ do
      err "{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}" TypeError
      err "{% macro m(a) %}{% endmacro %}{{ m(c=2) }}" TypeError
      err "{% macro m(a) %}{% endmacro %}{{ m(1, a=2) }}" TypeError
    it "lets macros see later sets of their defining scope" $
      ok "{% macro m() %}{{ x }}{% endmacro %}{% set x = 5 %}{{ m() }}" "5"
    it "does not show macros the caller's locals" $
      err "{% macro m() %}{{ y }}{% endmacro %}{% for y in [1] %}{{ m() }}{% endfor %}" UndefinedError
    it "includes templates in the current scope" $
      run [("main", "{% set a = 1 %}{% include \"inc\" %}[{{ b is defined }}]"), ("inc", "{{ a }}{% set b = 2 %}")] []
        `shouldBe` Right "1[False]"

  describe "inheritance" $ do
    it "renders blocks, overrides and super()" $
      run
        [ ("main", "{% extends \"base\" %}{% block b %}[{{ super() }}]{% endblock %}")
        , ("base", "<{% block b %}base{% endblock %}>{% block c %}c{% endblock %}") ]
        []
        `shouldBe` Right "<[base]>c"
    it "chains three levels" $
      run
        [ ("main", "{% extends \"mid\" %}{% block b %}A{{ super() }}{% endblock %}")
        , ("mid", "{% extends \"base\" %}{% block b %}B{{ super() }}{% endblock %}")
        , ("base", "{% block b %}C{% endblock %}") ]
        []
        `shouldBe` Right "ABC"
    it "renders text before extends and skips text after it" $
      run
        [ ("main", "head {% extends \"base\" %} skipped {% set n = 3 %}{% block b %}{{ n }}{% endblock %} tail")
        , ("base", "<{% block b %}{% endblock %}>") ]
        []
        `shouldBe` Right "head <3>"
    it "gives blocks the template scope, not the surrounding loop" $
      run
        [ ("main", "{% for x in [1] %}{% block b %}{{ x is defined }}{% endblock %}{% endfor %}") ] []
        `shouldBe` Right "False"
    it "reports super() with no parent block as undefined" $
      err "{% block b %}{{ super() }}{% endblock %}" UndefinedError
    it "uses the child's macros in the parent's blocks" $
      run
        [ ("main", "{% extends \"base\" %}{% macro m() %}M{% endmacro %}")
        , ("base", "{{ m() }}") ]
        []
        `shouldBe` Right "M"

  describe "errors" $ do
    it "reports syntax errors" $ do
      err "{% for %}" SyntaxError
      err "{% if true %}" SyntaxError
      err "{% endif %}" SyntaxError
      err "{{ 1" SyntaxError
      err "{# open" SyntaxError
      err "{{{ x }}}" SyntaxError
      err "{{ \"\\q\" }}" SyntaxError
      err "{% raw %}" SyntaxError
      err "{{ x is odd }}" SyntaxError
      err "{% block a %}{% endblock %}{% block a %}{% endblock %}" SyntaxError
      err "{% if true %}{% extends \"x\" %}{% endif %}" SyntaxError
      err "{% block a %}{% endblock b %}" SyntaxError
      err "{{ f(a=1, 2) }}" SyntaxError
      err "{% for a, b in x %}{% endfor %}" SyntaxError
    it "reports undefined values" $ do
      err "{{ missing }}" UndefinedError
      err "{% if missing %}{% endif %}" UndefinedError
      err "{{ missing + 1 }}" UndefinedError
      err "{{ missing == 1 }}" UndefinedError
      err "{{ missing|upper }}" UndefinedError
      rc "{{ a.b.c }}" [("a", mkDict [("b", mkDict [])])] `shouldBe` Left UndefinedError
      err "{{ nope() }}" UndefinedError
    it "reports type errors" $ do
      err "{{ 1 + \"a\" }}" TypeError
      err "{{ 1 / 0 }}" TypeError
      err "{{ 1 % 0 }}" TypeError
      err "{{ 1 < \"a\" }}" TypeError
      err "{{ 1 in 2 }}" TypeError
      err "{% for x in 5 %}{% endfor %}" TypeError
      err "{{ \"a\"() }}" TypeError
    it "reports missing templates" $ do
      err "{% include \"gone\" %}" TemplateNotFound
      err "{% extends \"gone\" %}" TemplateNotFound
      err "{% include 3 %}" TypeError
      err "{% include nope %}" UndefinedError
    it "reports syntax errors of included templates only when they are loaded" $ do
      run [("main", "ok"), ("bad", "{% if %}")] [] `shouldBe` Right "ok"
      run [("main", "{% include \"bad\" %}"), ("bad", "{% if %}")] [] `shouldBe` Left SyntaxError
    it "names the kinds" $
      map errorKindName [SyntaxError, FilterError, UndefinedError, TemplateNotFound, TypeError]
        `shouldBe` ["syntax", "filter", "undefined", "template", "type"]

  describe "worked examples" $ do
    it "renders the loop example" $
      rc "Hi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% endfor -%}\n{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}"
         [ ("user", mkDict [("name", str "Ada"), ("tags", mkList [str "x", str "y"])]), ("n", VInt 3) ]
        `shouldBe` Right "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']"

    it "renders the inheritance example" $
      run
        [ ("main", "{% extends \"base\" %}\n{% set count = items|length %}\n{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}")
        , ("base", "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}")
        , ("footer", "-- {{ title|lower }} {{ missing|default(\"end\") }}") ]
        [("title", str "T"), ("items", mkList [VInt 3, VInt 1, VInt 2])]
        `shouldBe` Right "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"
