{-# LANGUAGE OverloadedStrings #-}

module ParserSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.Either (isRight)
import Helpers (bs)
import Test.Hspec
import Tessera.Command
import Tessera.Error
import Tessera.Parser
import Tessera.Query
import Tessera.Value

-- | The error kind of a line, or @"ok"@.
kind :: String -> String
kind = either errorName (const "ok") . parseCommand . bs

nest :: Int -> String -> String
nest n inner = replicate n '[' ++ inner ++ replicate n ']'

spec :: Spec
spec = do
  describe "commands" $ do
    it "parses every command" $ do
      parseCommand "begin" `shouldBe` Right Begin
      parseCommand "  get \"a\"  " `shouldBe` Right (Get "a")
      parseCommand "put \"a\" {x:[1,2]}" `shouldSatisfy` isRight
      parseCommand "scan from \"a\" to \"b\" limit 3 reverse keys" `shouldSatisfy` isRight
      parseCommand "create index a.b" `shouldSatisfy` isRight
    it "reports the unknown command before anything else" $ do
      kind "frobnicate \"\\ud800\"" `shouldBe` "unknown-command"
      kind "PUT \"a\" 1" `shouldBe` "unknown-command"
    it "reports syntax errors" $ do
      mapM_ (\l -> (l, kind l) `shouldBe` (l, "syntax"))
        [ "", "   ", "1", "put \"a\"", "put 1 \"x\"", "put \"a\" 007", "put \"a\" -0", "put \"a\" +1"
        , "put \"a\" [1,]", "put \"a\" {a:1,}", "begin now", "scan limit 1 limit 2", "scan limit -1"
        , "scan limit 2147483648", "put \"a\" \"unterminated", "put \"a\" \"\\q\"", "put \"a\" =", "get \"a\" \"\\ud800\""
        , "put \"a\" 1 99999999999999999999", "create foo a", "find", "find a ==", "find a = 1"
        ]
    it "reports value errors in source order" $ do
      kind "put \"a\" 9223372036854775808" `shouldBe` "int-range"
      kind "put \"a\" -9223372036854775809" `shouldBe` "int-range"
      kind "put \"a\" -9223372036854775808" `shouldBe` "ok"
      kind "put \"a\" {x:1,x:2}" `shouldBe` "dup-field"
      kind "put \"a\" {x:1,x 2}" `shouldBe` "dup-field"
      kind "put \"\\ud800\" 1" `shouldBe` "bad-utf8"
      kind "put \"a\" \"\\ud83d\\ude00\"" `shouldBe` "ok"
      kind "put \"a\" \"\\ude00\"" `shouldBe` "bad-utf8"
      kind "put \"a\" \"\\ud800\\u00zz\"" `shouldBe` "syntax"
      kind "put \"\" 99999999999999999999" `shouldBe` "bad-key"
      kind (concat ["put \"", replicate 129 'k', "\" 1"]) `shouldBe` "bad-key"
    it "checks the depth limit at the moment the value is read" $ do
      kind ("put \"a\" " ++ nest 32 "") `shouldBe` "ok"
      kind ("put \"a\" " ++ nest 32 "1") `shouldBe` "depth"
      kind ("put \"a\" " ++ replicate 32 '[' ++ "99999999999999999999") `shouldBe` "depth"
      kind ("put \"a\" " ++ replicate 32 '[') `shouldBe` "depth"
      kind ("put \"a\" " ++ replicate 32 '[' ++ "-") `shouldBe` "syntax"
      kind ("put \"a\" " ++ replicate 30 '[' ++ "{x:[[1]],x:1}") `shouldBe` "depth"
      kind ("put \"a\" " ++ replicate 30 '[' ++ "{x:1,x:[[1]]}") `shouldBe` "dup-field"
    it "checks path limits per segment" $ do
      kind "unset \"a\" a.b.c.d.e.f.g.h.i." `shouldBe` "bad-path"
      kind ("unset \"a\" " ++ replicate 31 'x' ++ " .") `shouldBe` "bad-path"
      kind "unset \"a\" a.b.c.d.e.f.g.h" `shouldBe` "ok"
      kind "unset \"a\" a. b" `shouldBe` "ok"
  describe "predicates" $ do
    it "binds and tighter than or" $
      parsePred "a == 1 or b == 2 and c == 3"
        `shouldSatisfy` \p -> case p of Right (POr _ (PAnd _ _)) -> True; _ -> False
    it "allows keyword-named fields in comparisons" $ do
      parsePred "not == 1" `shouldSatisfy` isRight
      parsePred "exists == 1" `shouldSatisfy` isRight
    it "parses negation and parentheses" $
      parsePred "not(a == 1) and (b > 2 or exists c)" `shouldSatisfy` isRight
  describe "values" $
    it "parses literals" $ do
      parseValue "{b:1,\"a\":[null,true,\"x\"]}"
        `shouldSatisfy` \v -> fmap (BC.unpack . render) v == Right "{\"a\":[null,true,\"x\"],\"b\":1}"
