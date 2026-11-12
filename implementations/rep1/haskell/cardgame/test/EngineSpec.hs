module EngineSpec (spec) where

import Data.List (isInfixOf, isPrefixOf)
import Test.Hspec
import Test.QuickCheck

import Spiremark

header :: [String]
header =
  [ "CARDS test/data/cards.spire", "SEED 1", "SPIRE 10", "OPENING 0", "SHUFFLE off" ]

run :: [String] -> IO [String]
run ls = runMatchText (unlines ls)

-- | Event lines are those starting with a sequence number.
events :: [String] -> [String]
events = filter (\l -> case l of
  (c : _) -> c >= '0' && c <= '9'
  [] -> False)

seqNumbers :: [String] -> [Int]
seqNumbers = map (read . takeWhile (/= ' ')) . events

scriptLine :: Gen String
scriptLine = elements
  [ "A PASS", "B PASS", "A ATTACK", "B BLOCK", "A ATTACK #3", "B BLOCK #4:#3"
  , "A PLAY 1", "A PLAY 1 #3", "A PLAY 2 B", "B PLAY 1 A", "A ACT #3 1"
  , "A CONCEDE", "DUMP", "LEGAL", "VAULT", "CARD CIN-001", "# note", "bogus" ]

spec :: Spec
spec = do
  it "reports a fatal bad-setup without a START line" $
    runMatchText "CARDS test/data/cards.spire\nSEED 1\n" `shouldReturn` ["FATAL bad-setup"]
  it "reports bad-database for a missing database" $
    runMatchText "CARDS nowhere.spire\nSEED 1\nSTART\n" `shouldReturn` ["FATAL bad-database"]
  it "reports unknown-card for undefined setup entries" $
    run (header ++ ["DECK A ZZZ-999", "START"]) `shouldReturn` ["FATAL unknown-card"]
  it "starts a match and stops at the first decision point" $ do
    out <- run (header ++ ["START"])
    out `shouldBe`
      [ "1 GAME-START A", "2 TURN 1 A", "3 PHASE dawn", "4 EMBER A 1 1", "5 EMBER B 0 0"
      , "6 PHASE draw", "7 PHASE main1", "8 RESULT pending none" ]
  it "ends the match on concession and then rejects actions" $ do
    out <- run (header ++ ["START", "A CONCEDE", "A PASS", "DUMP"])
    out `shouldSatisfy` ("8 LOSE A concede" `elem`)
    out `shouldSatisfy` ("9 RESULT B concede" `elem`)
    out `shouldSatisfy` ("ERR 8 game-over" `elem`)
    out `shouldSatisfy` any ("decision - over" `isInfixOf`)
  it "enforces the error precedence of SPEC.md 24" $ do
    out <- run (header ++ ["HAND A CIN-003", "START", "X PASS", "B PASS", "A BLOCK", "A PLAY 5"])
    filter ("ERR" `isPrefixOf`) out `shouldBe`
      [ "ERR 8 bad-syntax", "ERR 9 not-your-turn", "ERR 10 wrong-decision", "ERR 11 no-such-card" ]
  it "draws when the turn limit is exceeded" $ do
    out <- run (header ++ ["TURNLIMIT 1", "DECK A CIN-001*3", "DECK B CIN-001*3", "START"]
                ++ ["A PASS", "B PASS", "A ATTACK", "A PASS", "B PASS", "A PASS", "B PASS"])
    out `shouldSatisfy` any ("RESULT draw turn-limit" `isInfixOf`)
  it "numbers events consecutively and ends with exactly one RESULT, for any script" $
    property $ forAll (listOf scriptLine) $ \script -> ioProperty $ do
      out <- run (header ++ ["DECK A CIN-001*30", "DECK B CIN-001*30", "HAND A CIN-003 CIN-016"
                            , "FIELD B TOK-001", "START"] ++ script)
      let evs = events out
      return $ seqNumbers out === [1 .. length evs]
        .&&. length (filter (isResult) evs) === 1
        .&&. (map isResult (drop (length evs - 1) evs) === [True])

isResult :: String -> Bool
isResult l = case words l of
  (_ : "RESULT" : _) -> True
  _ -> False
