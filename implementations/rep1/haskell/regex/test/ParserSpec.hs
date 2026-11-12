module ParserSpec (spec) where

import Test.Hspec

import qualified Regex.CharSet as CS
import Regex.Parser
import Regex.Syntax

ok :: String -> Node -> Expectation
ok src expected = parsePattern src `shouldBe` Right expected

bad :: String -> Expectation
bad src = parsePattern src `shouldSatisfy` either (const True) (const False)

spec :: Spec
spec = do
  it "parses literals and the empty pattern" $ do
    ok "" (Seq [])
    ok "ab" (Seq [Lit 97, Lit 98])
  it "gives | the lowest precedence and allows empty branches" $ do
    ok "a|" (Alt [Seq [Lit 97], Seq []])
    ok "||" (Alt [Seq [], Seq [], Seq []])
  it "numbers groups by their opening parenthesis" $
    ok "((a)b)(c)"
       (Seq [ Group 1 (Seq [Group 2 (Seq [Lit 97]), Lit 98]), Group 3 (Seq [Lit 99]) ])
  it "parses quantifiers" $ do
    ok "a*" (Seq [Repeat 0 Nothing (Lit 97)])
    ok "a+" (Seq [Repeat 1 Nothing (Lit 97)])
    ok "a?" (Seq [Repeat 0 (Just 1) (Lit 97)])
    ok "a{3}" (Seq [Repeat 3 (Just 3) (Lit 97)])
    ok "a{2,}" (Seq [Repeat 2 Nothing (Lit 97)])
    ok "a{2,5}" (Seq [Repeat 2 (Just 5) (Lit 97)])
    ok "a{0}" (Seq [Repeat 0 (Just 0) (Lit 97)])
  it "parses escapes" $ do
    ok "\\d" (Seq [Set CS.digits])
    ok "\\." (Seq [Lit 46])
    ok "\\ " (Seq [Lit 32])
    ok "\\D" (Seq [Set (CS.complement CS.digits)])
  it "parses classes" $ do
    ok "[abc]" (Seq [Set (CS.unions (map CS.singleton [97, 98, 99]))])
    ok "[a-c]" (Seq [Set (CS.range 97 99)])
    ok "[^a]" (Seq [Set (CS.complement (CS.singleton 97))])
    ok "[-a]" (Seq [Set (CS.union (CS.singleton 45) (CS.singleton 97))])
    ok "[a-]" (Seq [Set (CS.union (CS.singleton 97) (CS.singleton 45))])
    ok "[a\\-z]" (Seq [Set (CS.unions (map CS.singleton [97, 45, 122]))])
    ok "[a^]" (Seq [Set (CS.union (CS.singleton 97) (CS.singleton 94))])
    ok "[\\]\\[]" (Seq [Set (CS.union (CS.singleton 93) (CS.singleton 91))])
    ok "[\\d_]" (Seq [Set (CS.union CS.digits (CS.singleton 95))])
  it "rejects malformed patterns" $ do
    mapM_ bad ["(", ")", "a)", "[a", "[]", "*", "a**", "a{2", "a{3,2}", "\\", "\\q", "a|*", "^*", "[z-a]", "{"]
  it "reports the offset of an error" $
    parsePattern "ab)" `shouldBe` Left (ParseError 2 "unmatched ')'")
