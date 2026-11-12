module LexerParserSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Test.Hspec

import Kiln.Lexer
import Kiln.Parser
import Kiln.Syntax

parse :: String -> Either Int [Stmt]
parse = parseSource . BC.pack

errLine :: String -> Maybe Int
errLine = either Just (const Nothing) . parse

spec :: Spec
spec = do
  describe "lexing" $ do
    it "strips comments outside literals only" $
      fmap (map llTokens) (lexFile "let a = \"x # y\" # gone\n")
        `shouldBe` Right [[TIdent "let", TIdent "a", TSym "=", TDQ "x # y"]]
    it "joins physical lines while brackets are open" $
      fmap (map llNumber) (lexFile "let a = [1,\n2]\nlet b = 3\n") `shouldBe` Right [1, 3]
    it "reports an unterminated literal at the logical line's first line" $
      lexFile "let b = f(\n  \"unterminated\n)\n" `shouldBe` Left 1
    it "treats |> as one token and rejects a bare |" $ do
      fmap (map llTokens) (lexFile "a |> b\n") `shouldBe` Right [[TIdent "a", TSym "|>", TIdent "b"]]
      lexFile "a | b\n" `shouldBe` Left 1
    it "keeps a nested literal inside an interpolation in one token" $
      fmap (map llTokens) (lexFile "cmd write(\"{join(xs, \", \")}\\n\")\n")
        `shouldBe` Right [[TIdent "cmd", TIdent "write", TSym "(", TDQ "{join(xs, \", \")}\\n", TSym ")"]]
  describe "string literals" $ do
    it "decodes escapes and doubled braces" $
      readDoubleQuoted "a\\n{{b}}" `shouldBe` Just [RLit "a\n{b}"]
    it "rejects a bad escape, a lone } and an empty interpolation" $ do
      readDoubleQuoted "\\q" `shouldBe` Nothing
      readDoubleQuoted "a}b" `shouldBe` Nothing
      readDoubleQuoted "{ }" `shouldBe` Nothing
  describe "parsing" $ do
    it "gives * higher precedence than +" $
      parse "let x = 1 + 2 * 3\n"
        `shouldBe` Right [SLet "x" (EBinary Add (EIntLit 1) (EBinary Mul (EIntLit 2) (EIntLit 3)))]
    it "desugars pipes into calls" $
      parse "let x = a |> f |> g(1)\n"
        `shouldBe` Right [SLet "x" (ECall "g" [ECall "f" [EVar "a"], EIntLit 1])]
    it "parses when / elsewhen / otherwise" $
      fmap length (parse "when true {\n} elsewhen false {\n} otherwise {\n}\n") `shouldBe` Right 1
    it "reports the first grammar error in file order" $
      errLine "let x = 1\nlet = 2\nlet y = = 3\n" `shouldBe` Just 2
    it "reports lexical errors before earlier grammar errors" $
      errLine "let = 1\nlet x = \"abc\n" `shouldBe` Just 2
    it "reports an unterminated block at its header, innermost first" $
      errLine "when true {\n  each x in [1] {\n" `shouldBe` Just 2
    it "rejects a stray terminator at its own line" $
      errLine "let x = 1\n}\n" `shouldBe` Just 2
    it "rejects reserved words as names but allows them as call names" $ do
      errLine "let in = 1\n" `shouldBe` Just 1
      errLine "let x = 1 |> cost\n" `shouldBe` Nothing
    it "rejects a call applied to a non-identifier" $
      errLine "let x = f(1)(2)\n" `shouldBe` Just 1
    it "rejects positional arguments after keyword arguments" $
      errLine "use r(a = 1, 2)\n" `shouldBe` Just 1
    it "rejects duplicate rule parameters and misordered defaults" $ do
      errLine "rule r(a, a) {\n}\n" `shouldBe` Just 1
      errLine "rule r(a = 1, b) {\n}\n" `shouldBe` Just 1
