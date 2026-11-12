{-# LANGUAGE OverloadedStrings #-}

module LexerParserSpec (spec) where

import qualified Data.Text as T
import Control.Monad (forM_)
import Test.Hspec

import MiniSQL.Error
import MiniSQL.Lexer
import MiniSQL.Parser
import MiniSQL.Syntax

parses :: String -> Bool
parses s = either (const False) (const True) (parseOne s)

parseOne :: String -> Either Error Statement
parseOne s = case parseScript (T.pack s) of
  [r] -> r
  _ -> Left (SyntaxError "not one statement")

spec :: Spec
spec = do
  describe "tokenize" $ do
    it "is case-insensitive for keywords and identifiers" $
      tokenize "SeLeCt Foo" `shouldBe` [TKeyword KSelect, TIdent "foo"]
    it "lexes the longest operator" $
      tokenize "<= <> != == < > >= =" `shouldBe` [TLe, TNe, TNe, TEq, TLt, TGt, TGe, TEq]
    it "reads doubled quotes inside strings" $
      tokenize "'it''s'" `shouldBe` [TString "it's"]
    it "lets a string span lines and contain ; and --" $
      tokenize "'a;--\nb'" `shouldBe` [TString "a;--\nb"]
    it "treats -- as a comment" $
      tokenize "1 --5\n2" `shouldBe` [TInt 1, TInt 2]
    it "splits 1.5 into three tokens" $
      tokenize "1.5" `shouldBe` [TInt 1, TDot, TInt 5]
    it "keeps leading zeros out of the value" $
      tokenize "007" `shouldBe` [TInt 7]
    it "flags invalid characters and unterminated strings" $ do
      tokenize "\"x\"" `shouldBe` [TInvalid '"', TIdent "x", TInvalid '"']
      tokenize "select 'abc" `shouldBe` [TKeyword KSelect, TUnterminated]
      tokenize "é" `shouldBe` [TInvalid 'é']

  describe "splitStatements" $ do
    it "drops empty statements and keeps a final one without ;" $
      length (splitStatements (tokenize ";; select 1; -- c\n ; select 2")) `shouldBe` 2

  describe "parser" $ do
    it "accepts the supported statements" $
      all
        parses
        [ "CREATE TABLE t (a INTEGER, b TEXT)"
        , "INSERT INTO t VALUES (1, 'x'), (2, NULL)"
        , "DELETE FROM t WHERE a = 1"
        , "UPDATE t SET a = 1, b = 'x' WHERE a > 0"
        , "SELECT * FROM t x INNER JOIN u AS y ON x.a = y.a WHERE x.a > 1 GROUP BY x.a HAVING COUNT(*) > 1 ORDER BY 1 DESC, x.a LIMIT 3 OFFSET 1"
        , "SELECT count FROM t"
        , "SELECT count (*) FROM t"
        ]
        `shouldBe` True
    describe "rejects unsupported or malformed SQL" $
      forM_
        [ "DROP TABLE t"
        , "SELECT * FROM a LEFT JOIN b ON 1"
        , "SELECT * FROM a, b, c"
        , "SELECT a FROM t WHERE a IN (1)"
        , "SELECT a AS left FROM t"
        , "CREATE TABLE t (text TEXT)"
        , "CREATE TABLE t (a REAL)"
        , "CREATE TABLE t ()"
        , "INSERT INTO t (a) VALUES (1)"
        , "SELECT a FROM t LIMIT -1"
        , "SELECT a FROM t OFFSET 1"
        , "SELECT a FROM t HAVING a = 1"
        , "SELECT a FROM t GROUP BY a + 1"
        , "SELECT foo(1)"
        , "SELECT SUM(*)"
        , "SELECT 1.5"
        , "SELECT a || b"
        , "SELECT 1 + "
        ]
        $ \sql -> it sql $ parses sql `shouldBe` False
    it "gives NOT a lower precedence than =" $
      parseExpr "NOT a = 1" `shouldBe` Right (ENot (ECmp Eq (ECol Nothing "a") (EInt 1)))
    it "binds ordering operators tighter than equality" $
      parseExpr "1 < 2 = 1"
        `shouldBe` Right (ECmp Eq (ECmp Lt (EInt 1) (EInt 2)) (EInt 1))
    it "applies unary minus before %" $
      parseExpr "-5 % 3" `shouldBe` Right (EArith Mod (ENeg (EInt 5)) (EInt 3))
    it "parses IS NOT NULL and NOT LIKE" $ do
      parseExpr "a IS NOT NULL" `shouldBe` Right (ENot (EIsNull (ECol Nothing "a")))
      parseExpr "a NOT LIKE 'x'" `shouldBe` Right (ENot (ELike (ECol Nothing "a") (EStr "x")))
    it "tells ordinals and aliases from expressions in ORDER BY" $
      case parseOne "SELECT a FROM t ORDER BY 1, a, (1), a + 1" of
        Right (SelectStmt s) ->
          map (\(OrderTerm k _) -> k) (selOrderBy s)
            `shouldBe` [OrdOrdinal 1, OrdName "a", OrdExpr (EInt 1), OrdExpr (EArith Add (ECol Nothing "a") (EInt 1))]
        other -> expectationFailure (show other)
