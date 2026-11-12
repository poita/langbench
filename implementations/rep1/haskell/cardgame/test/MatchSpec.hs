module MatchSpec (spec) where

import Test.Hspec

import Spiremark

setupOf :: String -> Maybe Setup
setupOf s = either (const Nothing) (Just . fst) (parseMatch s)

-- | The setup of a match file that is expected to be valid.
setupOrFail :: String -> IO Setup
setupOrFail s = maybe (expectationFailure "setup rejected" >> fail "setup rejected") return (setupOf s)

spec :: Spec
spec = do
  describe "setup block" $ do
    it "applies defaults" $ do
      su <- setupOrFail "CARDS x\nSEED 1\nSTART\n"
      (suSpire su, suOpening su, suMaxCap su, suHandMax su, suTurnLimit su)
        `shouldBe` (25, 5, 10, 7, 200)
      (suFirst su, suShuffle su, suTrace su) `shouldBe` (A, True, TraceNone)
    it "reads every option" $ do
      su <- setupOrFail (unlines
            [ "# comment", "CARDS a/b.spire", "SEED 18446744073709551615", "SPIRE 007"
            , "OPENING 0", "MAXCAP 3", "HANDMAX 100", "TURNLIMIT 5", "FIRST B"
            , "SHUFFLE off", "TRACE state", "CAP A 2", "CAP B 4"
            , "DECK A CIN-001*3 CIN-002", "  ", "START" ])
      suSpire su `shouldBe` 7
      suSeed su `shouldBe` maxBound
      (suFirst su, suShuffle su, suTrace su) `shouldBe` (B, False, TraceState)
      (suCapA su, suCapB su) `shouldBe` (2, 4)
      suZones su `shouldBe` [(A, ZDeck, [("CIN-001", 3), ("CIN-002", 1)])]
    it "numbers script lines including comments" $
      fmap snd (parseMatch "CARDS x\nSEED 1\nSTART\n# c\nA PASS\n")
        `shouldBe` Right [(4, "# c"), (5, "A PASS")]
    it "rejects each kind of setup violation" $ do
      let bad s = setupOf s `shouldBe` Nothing
      bad "SEED 1\nSTART\n"                       -- missing CARDS
      bad "CARDS x\nSTART\n"                      -- missing SEED
      bad "CARDS x\nSEED 1\n"                     -- missing START
      bad "CARDS x\nSEED 1\nSEED 2\nSTART\n"      -- duplicate
      bad "CARDS x\nSEED 1\nBOGUS 1\nSTART\n"     -- unknown word
      bad "CARDS x\nSEED -1\nSTART\n"             -- sign
      bad "CARDS x\nSEED 1\nSPIRE 1000001\nSTART\n"
      bad "CARDS x\nSEED 1\nHANDMAX 101\nSTART\n"
      bad "CARDS x\nSEED 1\nTRACE all\nSTART\n"
      bad "CARDS x\nSEED 1\nDECK A CIN-001*1001\nSTART\n"
      bad "CARDS x\nSEED 1\nDECK A *3\nSTART\n"
      bad "CARDS x\nSEED 1\nSTART now\n"
    it "allows CAP A and CAP B once each" $ do
      setupOf "CARDS x\nSEED 1\nCAP A 1\nCAP B 1\nSTART\n" `shouldSatisfy` (/= Nothing) . fmap suCapA
      setupOf "CARDS x\nSEED 1\nCAP A 1\nCAP A 2\nSTART\n" `shouldBe` Nothing
  describe "script lines" $ do
    it "parses actions" $ do
      parseScriptLine "A PASS" `shouldBe` SAction A Pass
      parseScriptLine "B CONCEDE" `shouldBe` SAction B Concede
      parseScriptLine "A PLAY 007 A #3 ~2" `shouldBe`
        SAction A (Play 7 [TgtPlayer A, TgtObj 3, TgtEntry 2])
      parseScriptLine "A ACT #4 2 B" `shouldBe` SAction A (Act 4 2 [TgtPlayer B])
      parseScriptLine "A ATTACK #1 #2" `shouldBe` SAction A (Attack [1, 2])
      parseScriptLine "B BLOCK #4:#2" `shouldBe` SAction B (Block [(4, 2)])
      parseScriptLine "A ATTACK" `shouldBe` SAction A (Attack [])
    it "parses directives" $ do
      parseScriptLine "DUMP" `shouldBe` SDump
      parseScriptLine "LEGAL" `shouldBe` SLegal
      parseScriptLine "VAULT" `shouldBe` SVault
      parseScriptLine "CARD CIN-001" `shouldBe` SCard "CIN-001"
    it "flags malformed lines" $
      mapM_ (\l -> parseScriptLine l `shouldBe` SBadSyntax)
        [ "X PASS", "a pass", "A PASS now", "A PLAY", "A PLAY x", "A PLAY -1"
        , "A PLAY 1 C", "A ACT 4 1", "A ATTACK 3", "A BLOCK #1", "A BLOCK #1:", "DUMP x"
        , "CARD", "CARD a b", "A PLAY 18446744073709551616", "A" ]
