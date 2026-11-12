{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import Template
import Template.Filters (applyFilter)
import Template.Lexer (Tok (..), lexExpression)
import Template.Ops (binary, compareValues, valuesEqual)
import Template.Syntax (BinOp (..), CmpOp (..))
import Template.Value (formatFloat, repr)

-- | Render @main@ (with the given extra templates) against a JSON context.
run :: Text -> [(Text, Text)] -> Text -> Either ErrorKind Text
run ctxJson others src = case parseJson ctxJson of
  Right (VDict d) -> render (dictToList d) (("main", src) : others) "main"
  _ -> error "bad test context"

rend :: Text -> Either ErrorKind Text
rend = run "{}" []

withCtx :: Text -> Text -> Either ErrorKind Text
withCtx c = run c []

main :: IO ()
main = hspec $ do
  describe "Template.Lexer" $ do
    it "tokenizes operators longest-match" $
      lexExpression "a ** b // c" `shouldBe`
        Right [TName "a", TOp "**", TName "b", TOp "//", TName "c"]
    it "reads numbers and strings with escapes" $
      lexExpression "1 2.5 'a\\n\"'" `shouldBe`
        Right [TInt 1, TFloat 2.5, TStr "a\n\""]
    it "rejects bad escapes and characters" $ do
      lexExpression "'\\x'" `shouldBe` Left ErrSyntax
      lexExpression "a $ b" `shouldBe` Left ErrSyntax
      lexExpression "'abc" `shouldBe` Left ErrSyntax

  describe "Template.Json" $ do
    it "distinguishes integers and floats" $
      fmap show (parseJson "[1, 1.0, 1e2, -3]") `shouldBe` Right "[1, 1.0, 100.0, -3]"
    it "keeps object order and decodes escapes" $
      fmap show (parseJson "{\"b\": \"\\u00e9\\n\", \"a\": null}") `shouldBe`
        Right "{'b': 'é\\n', 'a': None}"
    it "rejects malformed documents" $
      parseJson "{\"a\": }" `shouldSatisfy` either (const True) (const False)

  describe "formatFloat" $ do
    it "follows Python's repr layout" $ do
      map formatFloat [3, 0.5, 1e15, 1e16, 0.0001, 0.00001, 1.5e300, 0.1 + 0.2, -0.0, 0]
        `shouldBe` ["3.0", "0.5", "1000000000000000.0", "1e+16", "0.0001", "1e-05"
                   , "1.5e+300", "0.30000000000000004", "-0.0", "0.0"]
    it "round-trips every double" $ property $ \d ->
      not (isNaN d || isInfinite d) ==>
        read (T.unpack (T.replace "e+" "e" (formatFloat d))) === (d :: Double)

  describe "Template.Ops" $ do
    it "does exact integer arithmetic and float division" $ do
      show (binary Div (VInt 6) (VInt 3)) `shouldBe` "Right 2.0"
      show (binary FloorDiv (VInt (-7)) (VInt 2)) `shouldBe` "Right -4"
      show (binary Mod (VInt (-7)) (VInt 3)) `shouldBe` "Right 2"
      show (binary Mod (VInt 7) (VInt (-3))) `shouldBe` "Right -2"
      show (binary Pow (VInt 2) (VInt (-1))) `shouldBe` "Right 0.5"
    it "reports division by zero as a type error" $
      either id (const ErrSyntax) (binary Div (VInt 1) (VInt 0)) `shouldBe` ErrType
    it "treats booleans as integers" $ do
      valuesEqual (VBool True) (VInt 1) `shouldBe` True
      valuesEqual (VInt 1) (VStr "1") `shouldBe` False
    it "orders strings by code point and rejects mixed kinds" $ do
      compareValues Lt (VStr "ab") (VStr "abc") `shouldBe` Right True
      compareValues Lt (VStr "a") (VInt 1) `shouldBe` Left ErrType
    it "implements in on strings, lists and dicts" $ do
      compareValues In (VStr "b") (VStr "abc") `shouldBe` Right True
      compareValues In (VInt 1) (VStr "abc") `shouldBe` Left ErrType
      compareValues NotIn (VInt 3) (VList mempty) `shouldBe` Right True

  describe "Template.Filters" $ do
    it "int parses strings like the spec says" $
      [ repr v | s <- [" 42 ", "-7", "3.9", "-3.9", "1e3", ".5", "abc", "1x"]
               , Right v <- [applyFilter "int" (VStr s) []] ]
        `shouldBe` ["42", "-7", "3", "-3", "1000", "0", "0", "0"]
    it "checks undefined input before the argument count" $ do
      applyFilter "upper" VUndefined [VInt 1] `shouldBe'` ErrUndefined
      applyFilter "default" VUndefined [VInt 1, VInt 2] `shouldBe'` ErrType
    it "sort is stable and ignores ASCII case" $
      rend "{{ ['b', 'A', 'a', 'B']|sort|join(',') }}" `shouldBe` Right "A,a,b,B"

  describe "printing" $ do
    it "prints lists and dicts with Python reprs" $
      withCtx "{\"d\": {\"k\": [2.0, \"it's\"]}}" "{{ [1, 'a', true, none, d] }}"
        `shouldBe` Right "[1, 'a', True, None, {'k': [2.0, \"it's\"]}]"
    it "prints floats shortest" $
      rend "{{ 0.1 + 0.2 }} {{ 7 / 2 }} {{ 2 ** 70 }}" `shouldBe`
        Right "0.30000000000000004 3.5 1180591620717411303424"

  describe "expressions" $ do
    it "applies the specified precedence" $ do
      rend "{{ -2 ** 2 }}" `shouldBe` Right "4"
      rend "{{ 1 + 2 ~ 3 }}" `shouldBe` Left ErrType   -- ~ binds tighter than +
      rend "{{ 1 ~ 2 + 3 }}" `shouldBe` Left ErrType
      rend "{{ 2 ** 3 ** 2 }}" `shouldBe` Right "64"     -- left-associative
      rend "{{ 2 * 3|string_free }}" `shouldBe` Left ErrFilter
      rend "{{ not 1 == 2 }}" `shouldBe` Right "True"
    it "and/or return the deciding operand" $
      rend "{{ 0 or 'x' }}{{ '' and 1 }}|{{ 1 and 2 }}" `shouldBe` Right "x|2"
    it "chains comparisons with short-circuiting" $
      rend "{{ 1 < 2 < 3 }} {{ 3 < 2 < missing }}" `shouldBe` Right "True False"
    it "indexes with negative indices and misses to undefined" $ do
      rend "{{ [1, 2, 3][-1] }}{{ 'abc'[1] }}" `shouldBe` Right "3b"
      rend "{{ [1][5] is defined }}" `shouldBe` Right "False"

  describe "statements" $ do
    it "for exposes loop and runs else on empty input" $ do
      rend "{% for x in [7, 8] %}{{ loop.index }}{{ x }}{% if loop.last %}.{% endif %}{% endfor %}"
        `shouldBe` Right "1728."
      rend "{% for x in [] %}a{% else %}none{% endfor %}" `shouldBe` Right "none"
    it "set inside a loop does not leak" $
      rend "{% set a = 1 %}{% for x in [1] %}{% set a = 2 %}{{ a }}{% endfor %}{{ a }}"
        `shouldBe` Right "21"
    it "iterates dicts by key in document order" $
      withCtx "{\"d\": {\"z\": 1, \"a\": 2}}" "{% for k in d %}{{ k }}{{ d[k] }}{% endfor %}"
        `shouldBe` Right "z1a2"
    it "supports range" $
      rend "{{ range(5, 0, -2)|join(',') }}" `shouldBe` Right "5,3,1"

  describe "whitespace control" $ do
    it "strips adjacent whitespace only" $ do
      rend "a  {{- 1 -}}  b" `shouldBe` Right "a1b"
      rend "a {# c -#}  b" `shouldBe` Right "a b"
      rend "a\n  {%- if true -%}\n  x\n{%- endif %}" `shouldBe` Right "ax"
    it "keeps newlines after tags without a dash" $
      rend "{% if true %}\nx{% endif %}" `shouldBe` Right "\nx"

  describe "macros" $ do
    it "binds defaults in the macro scope and supports recursion" $
      rend (T.unlines
        [ "{% macro f(n, k=n * 2) %}{% if n <= 0 %}{{ k }}{% else %}{{ f(n - 1) }}{% endif %}{% endmacro -%}"
        , "{{ f(3) }}{{ f(0, k=9) }}" ])
        `shouldBe` Right "09\n"
    it "reports macro misuse as type errors" $ do
      rend "{% macro f(a) %}{% endmacro %}{{ f(1, 2) }}" `shouldBe` Left ErrType
      rend "{% macro f(a) %}{% endmacro %}{{ f(1, a=2) }}" `shouldBe` Left ErrType
      rend "{% macro f(a) %}{{ a }}{% endmacro %}{{ f() }}" `shouldBe` Left ErrUndefined

  describe "include and inheritance" $ do
    it "include sees the includer's scope" $
      run "{\"t\": \"T\"}" [("p", "-{{ t }}{{ v }}")] "{% set v = 1 %}{% include 'p' %}"
        `shouldBe` Right "-T1"
    it "renders the spec's inheritance example" $
      run "{\"title\": \"T\", \"items\": [3, 1, 2]}"
        [ ("base", T.intercalate "\n"
            [ "{% macro item(v) %}#{{ v }}{% endmacro -%}"
            , "<h1>{% block title %}{{ title }}{% endblock %}</h1>"
            , "{% block body %}{{ count }} items{% endblock %}"
            , "{% include \"footer\" %}" ])
        , ("footer", "-- {{ title|lower }} {{ missing|default(\"end\") }}") ]
        (T.intercalate "\n"
          [ "{% extends \"base\" %}"
          , "{% set count = items|length %}"
          , "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}" ])
        `shouldBe` Right "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"
    it "supports three-level chains with super()" $
      run "{}" [("b", "{% extends 'c' %}{% block x %}b{{ super() }}{% endblock %}")
               ,("c", "[{% block x %}c{% endblock %}]")]
        "{% extends 'b' %}{% block x %}a{{ super() }}{% endblock %}"
        `shouldBe` Right "[abc]"
    it "reports super() without a parent block as undefined" $
      rend "{% block x %}{{ super() }}{% endblock %}" `shouldBe` Left ErrUndefined
    it "loads templates lazily" $
      run "{}" [("bad", "{% if %}")] "ok" `shouldBe` Right "ok"
    it "reports missing templates" $
      rend "{% include 'nope' %}" `shouldBe` Left ErrTemplate

  describe "errors" $ do
    it "classifies syntax errors" $
      mapM_ (\t -> rend t `shouldBe` Left ErrSyntax)
        [ "{{ x", "{% if x %}", "{# open", "{% endif %}", "{% foo %}", "{{ }}"
        , "{{{ x }}}", "{% for a, b in x %}{% endfor %}", "{{ x - }}"
        , "{% block a %}{% endblock b %}", "{% block a %}{% endblock %}{% block a %}{% endblock %}"
        , "{% if true %}{% extends 'x' %}{% endif %}", "{{ [1,] }}", "{{ f(a=1, 2) }}"
        , "{{ 1 is odd }}" ]
    it "reports syntax before filter errors, and filters before runtime errors" $ do
      rend "{{ 1|nope }}{% if %}" `shouldBe` Left ErrSyntax
      rend "{{ 1 + 'a' }}{{ 1|nope }}" `shouldBe` Left ErrFilter
    it "is all-or-nothing" $
      rend "before {{ missing }}" `shouldBe` Left ErrUndefined
    it "classifies undefined misuse" $ do
      mapM_ (\t -> rend t `shouldBe` Left ErrUndefined)
        [ "{{ a }}", "{{ a.b }}", "{% if a %}{% endif %}", "{{ a == 1 }}", "{{ loop }}"
        , "{{ a|upper }}", "{% for x in a %}{% endfor %}", "{{ a() }}" ]
      withCtx "{\"a\": {\"b\": 1}}" "{{ a.c.d }}" `shouldBe` Left ErrUndefined
    it "classifies type errors" $
      mapM_ (\t -> rend t `shouldBe` Left ErrType)
        [ "{{ 'a' + 1 }}", "{{ 1 // 0 }}", "{{ 1 < 'a' }}", "{% for x in 5 %}{% endfor %}"
        , "{{ 5|length }}", "{{ 1 in none }}", "{{ 5() }}", "{{ range('a') }}"
        , "{{ [1, 'a']|sort }}" ]

  describe "Template.Document" $ do
    it "splits the input and renders the first template" $ do
      let doc = "{\"n\": 3}\n--\n=== main\nHello {{ n }}!\n=== other\nunused\n"
      case parseDocument doc of
        Left e -> expectationFailure e
        Right d -> map fst (docTemplates d) `shouldBe` ["main", "other"]
      renderDocument doc >>= (`shouldBe` Right "Hello 3!\n")
    it "keeps a blank line before a header as part of the body" $
      case parseDocument "{}\n--\n=== a\nx\n\n=== b\ny\n" of
        Right d -> map snd (docTemplates d) `shouldBe` ["x\n", "y"]
        Left e -> expectationFailure e
    it "prints the error line" $
      renderDocument "{}\n--\n=== main\n{{ x }}\n" >>= (`shouldBe` Right "error: undefined\n")
  where
    shouldBe' r k = r `shouldSatisfy` either (== k) (const False)
