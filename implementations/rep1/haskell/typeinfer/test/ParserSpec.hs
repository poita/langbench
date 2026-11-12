module ParserSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Generators
import Language.TypeInfer

int :: String -> Expr
int = ELit . LInt

parses :: String -> Expr -> Expectation
parses src e = parseExpr src `shouldBe` Right e

spec :: Spec
spec = do
  describe "expressions" $ do
    it "gives application higher precedence than operators" $
      "f x + g y * 2" `parses`
        EBin Add (EApp (EVar "f") (EVar "x"))
                 (EBin Mul (EApp (EVar "g") (EVar "y")) (int "2"))
    it "makes :: right associative and looser than +" $
      "1 :: f x :: l" `parses`
        ECons (int "1") (ECons (EApp (EVar "f") (EVar "x")) (EVar "l"))
    it "makes && looser than comparison" $
      "a < b && c" `parses` EBin And (EBin Lt (EVar "a") (EVar "b")) (EVar "c")
    it "makes - left associative" $
      "1 - 2 - 3" `parses` EBin Sub (EBin Sub (int "1") (int "2")) (int "3")
    it "desugars multi-parameter fun" $
      "fun x y -> x" `parses` EFun "x" (EFun "y" (EVar "x"))
    it "lets a fun body stop at a comma" $
      "(fun x -> x, 1)" `parses` ETuple [EFun "x" (EVar "x"), int "1"]
    it "lets a fun body stop at a semicolon in a list" $
      "[fun x -> x; fun y -> 1]" `parses`
        EList [EFun "x" (EVar "x"), EFun "y" (int "1")]
    it "lets a let body stop at a comma" $
      "(let y = 1 in y, 2)" `parses` ETuple [ELet "y" (int "1") (EVar "y"), int "2"]
    it "extends an else branch as far right as possible" $
      "if a then b else c + 1" `parses`
        EIf (EVar "a") (EVar "b") (EBin Add (EVar "c") (int "1"))
    it "desugars let with parameters" $
      "let f x y = x in f" `parses` ELet "f" (EFun "x" (EFun "y" (EVar "x"))) (EVar "f")
    it "desugars let rec with parameters" $
      "let rec f x y = y in f" `parses`
        ELetRec "f" "x" (EFun "y" (EVar "y")) (EVar "f")
    it "distinguishes unit, parentheses, tuples and lists" $ do
      "()" `parses` ELit LUnit
      "(1)" `parses` int "1"
      "(1, 2, 3)" `parses` ETuple [int "1", int "2", int "3"]
      "[]" `parses` EList []
      "[1; 2]" `parses` EList [int "1", int "2"]
    it "keeps keyword prefixes inside identifiers" $
      "letx inx funny" `parses` EApp (EApp (EVar "letx") (EVar "inx")) (EVar "funny")
    it "accepts arbitrarily long integer literals" $
      let digits = replicate 5000 '7' in digits `parses` int digits
    it "rejects malformed input" $
      parseExpr "(1 + " `shouldSatisfy` either (const True) (const False)

  describe "programs" $ do
    it "accepts an empty program" $ do
      parseProgram "" `shouldBe` Right []
      parseProgram " \n\t " `shouldBe` Right []
    it "recognises the three declaration forms" $
      parseProgram "let x = 1;; let rec f n = f n;; x;;" `shouldBe`
        Right [DLet "x" (int "1"), DLetRec "f" "n" (EApp (EVar "f") (EVar "n")), DExpr (EVar "x")]
    it "needs no whitespace around ;;" $
      parseProgram "1;;2;;" `shouldBe` Right [DExpr (int "1"), DExpr (int "2")]
    it "lexes -> and ;; and <= as single tokens" $
      parseProgram "fun x->x<=1;;" `shouldBe`
        Right [DExpr (EFun "x" (EBin Le (EVar "x") (int "1")))]
    it "reports a position for a lexical error" $
      parseProgram "1;;\n  @" `shouldBe`
        Left (ParseError (Pos 2 3) "unexpected character '@'")
    it "parses a 100000-element list" $
      let src = "[" ++ concatMap (++ ";") (replicate 99999 "1") ++ "1];;"
      in fmap (map (\case DExpr (EList es) -> length es; _ -> 0)) (parseProgram src)
           `shouldBe` Right [100000]

  describe "renderExpr / renderDecl" $ do
    it "round-trips expressions" $
      property $ forAll genExpr $ \e -> parseExpr (renderExpr e) === Right e
    it "round-trips programs" $
      property $ forAll genProgram $ \p ->
        parseProgram (concatMap renderDecl p) === Right p
