module LexParseSpec (spec) where

import qualified Data.ByteString as BS
import Test.Hspec

import Kiln.Lexer
import Kiln.Parser
import Kiln.Syntax

parseErr :: BS.ByteString -> Maybe Int
parseErr src = either Just (const Nothing) (parseSource src)

expr :: BS.ByteString -> Maybe Expr
expr src = tokenizeLine src >>= parseExprTokens

spec :: Spec
spec = do
  describe "lexical structure" $ do
    it "strips comments outside strings only" $
      fmap (map llTokens) (lexSource "let a = \"x#y\" # note\n")
        `shouldBe` Right [[TIdent "let", TIdent "a", TSym "=", TDq "x#y"]]
    it "joins lines while brackets are open and reports the first line" $
      parseErr "let b = f(\n  \"unterminated\n)\n" `shouldBe` Just 1
    it "treats a nested string in an interpolation as part of the literal" $
      fmap (map llTokens) (lexSource "cmd write(\"{join(xs, \", \")}\\n\")")
        `shouldBe` Right [[TIdent "cmd", TIdent "write", TSym "(", TDq "{join(xs, \", \")}\\n", TSym ")"]]
    it "reports a bare | as a lexical error" $ parseErr "let a = 1 | 2" `shouldBe` Just 1
    it "reports lexical errors before earlier grammar errors" $
      parseErr "let = 1\nlet x = \"abc\n" `shouldBe` Just 2
    it "reports a negative bracket depth" $ parseErr "let a = 1)\n" `shouldBe` Just 1
    it "reports a bracket open at end of file at its first line" $
      parseErr "\nlet a = (1\n+ 2\n" `shouldBe` Just 2

  describe "block structure" $ do
    it "parses when / elsewhen / otherwise" $
      parseErr "when true {\n} elsewhen false {\n} otherwise {\n}\n" `shouldBe` Nothing
    it "reports an unterminated block at its header" $
      parseErr "let a = 1\nstep {\n  out \"out/a\"\n" `shouldBe` Just 2
    it "reports the innermost unterminated block" $
      parseErr "when true {\neach x in [1] {\n" `shouldBe` Just 2
    it "reports a stray terminator at its own line" $ parseErr "let a = 1\n}\n" `shouldBe` Just 2
    it "rejects otherwise after otherwise" $
      parseErr "when true {\n} otherwise {\n} otherwise {\n}\n" `shouldBe` Just 3
    it "rejects elsewhen closing a step" $
      parseErr "step {\n} elsewhen true {\n}\n" `shouldBe` Just 2
    it "rejects a step field outside a step" $ parseErr "out \"out/a\"\n" `shouldBe` Just 1
    it "rejects a statement inside a step" $ parseErr "step {\nlet a = 1\n}\n" `shouldBe` Just 2
    it "rejects a lone {" $ parseErr "{\n" `shouldBe` Just 1

  describe "reserved words and names" $ do
    it "rejects a reserved word as a variable" $ parseErr "let in = 1\n" `shouldBe` Just 1
    it "allows a reserved word as a call name" $ expr "cost(1)" `shouldBe` Just (ECall "cost" [EInt 1])
    it "allows a reserved word as a pipe target" $ expr "1 |> cost" `shouldBe` Just (ECall "cost" [EInt 1])
    it "rejects duplicate parameters" $ parseErr "rule r(a, a) {\n}\n" `shouldBe` Just 1
    it "rejects a required parameter after a default" $ parseErr "rule r(a = 1, b) {\n}\n" `shouldBe` Just 1
    it "rejects a positional use argument after a keyword" $ parseErr "use r(a = 1, 2)\n" `shouldBe` Just 1
    it "rejects equal each variables" $ parseErr "each a, a in [] {\n}\n" `shouldBe` Just 1

  describe "expressions" $ do
    it "applies |> left-associatively" $
      expr "x |> f |> g(1)" `shouldBe` Just (ECall "g" [ECall "f" [EVar "x"], EInt 1])
    it "gives ~ lower precedence than +" $
      expr "a ~ b + c" `shouldBe` Just (EBinary ConcatStr (EVar "a") (EBinary Add (EVar "b") (EVar "c")))
    it "gives ++ lower precedence than ~" $
      expr "a ++ b ~ c" `shouldBe` Just (EBinary ConcatList (EVar "a") (EBinary ConcatStr (EVar "b") (EVar "c")))
    it "binds unary minus tighter than *" $
      expr "-a * b" `shouldBe` Just (EBinary Mul (EUnary Neg (EVar "a")) (EVar "b"))
    it "rejects calling a non-identifier" $ expr "f(1)(2)" `shouldBe` Nothing
    it "accepts trailing commas" $ expr "[1, 2,]" `shouldBe` Just (EList [EInt 1, EInt 2])
    it "indexes any expression" $ expr "[1][0]" `shouldBe` Just (EIndex (EList [EInt 1]) (EInt 0))

  describe "string literals" $ do
    it "reads escapes" $ expr "\"a\\n\\t\\\\\\\"\\0\"" `shouldBe` Just (EStr "a\n\t\\\"\0")
    it "reads brace doubling" $ expr "\"{{x}}\"" `shouldBe` Just (EStr "{x}")
    it "reads single-quoted literals verbatim" $ expr "'a\\n{x}''q'" `shouldBe` Just (EStr "a\\n{x}'q")
    it "rejects a bad escape" $ expr "\"\\q\"" `shouldBe` Nothing
    it "rejects a lone }" $ expr "\"a}b\"" `shouldBe` Nothing
    it "rejects an empty interpolation" $ expr "\"{ }\"" `shouldBe` Nothing
    it "parses interpolation bodies" $
      expr "\"x{n * 2}\"" `shouldBe` Just (EInterp [PLit "x", PHole (EBinary Mul (EVar "n") (EInt 2))])
