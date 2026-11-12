module CardSpec (spec) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as M
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec

import Spiremark

card :: String -> String
card body = "(card AAA-001 (name \"One\") " ++ body ++ ")"

mainDb :: IO CardDb
mainDb = loadDatabase "test/data/cards.spire" >>= maybe (fail "cards.spire invalid") return

spec :: Spec
spec = do
  describe "shipped databases" $ do
    it "accepts the main database with 200 cards" $ do
      db <- mainDb
      M.size db `shouldBe` 200
    forM_ ["extra", "lexer", "empty"] $ \n ->
      it ("accepts " ++ n ++ ".spire") $ do
        r <- loadDatabase ("test/data" </> (n ++ ".spire"))
        r `shouldSatisfy` maybe False (const True)
    it "treats a missing file as invalid" $ do
      r <- loadDatabase "test/data/nonexistent.spire"
      r `shouldSatisfy` maybe True (const False)
  describe "invalid databases" $ do
    files <- runIO (listDirectory "test/data/bad")
    forM_ files $ \f ->
      it ("rejects bad/" ++ f) $ do
        r <- loadDatabase ("test/data/bad" </> f)
        r `shouldSatisfy` maybe True (const False)
  describe "validation rules" $ do
    let ok s = parseDatabase s `shouldSatisfy` maybe False (const True)
        bad s = parseDatabase s `shouldSatisfy` maybe True (const False)
    it "accepts a minimal unit" $ ok (card "(type unit) (cost 1) (body 1 1)")
    it "requires a body on units only" $ do
      bad (card "(type unit) (cost 1)")
      bad (card "(type relic) (cost 1) (body 1 1)")
    it "limits keywords by card type" $ do
      ok (card "(type rite) (cost 1) (keywords swift) (resolve (nothing))")
      bad (card "(type unit) (cost 1) (body 1 1) (keywords swift)")
      bad (card "(type relic) (cost 1) (keywords vigil) (aura (swapstats self))")
    it "requires act abilities to have exactly one cost" $ do
      ok (card "(type unit) (cost 1) (body 1 1) (act (cost (once)) (draw 1 you))")
      bad (card "(type unit) (cost 1) (body 1 1) (act (draw 1 you))")
    it "rejects duplicate ids" $
      bad (card "(type unit) (cost 0) (body 1 1)" ++ card "(type unit) (cost 0) (body 1 1)")
    it "rejects summoning a rite but allows conjuring one" $ do
      let rite = "(card BBB-002 (name \"R\") (type rite) (cost 1) (resolve (nothing)))"
      bad (card "(type rite) (cost 1) (resolve (summon BBB-002 1 you))" ++ rite)
      ok (card "(type rite) (cost 1) (resolve (conjure BBB-002 1 you))" ++ rite)
  describe "CARD block" $ do
    it "prints known cards canonically" $ do
      db <- mainDb
      cardBlock db "DSK-020" `shouldBe`
        [ "CARD BEGIN DSK-020", "name Grim Harvester", "type unit", "cost 3", "body 2/2"
        , "tags dusk,undead", "keywords -"
        , "ability 1 on spire-loss - (counters 1 self)"
        , "ability 2 act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))"
        , "CARD END" ]
    it "prints unknown cards" $ do
      db <- mainDb
      cardBlock db "ZZZ-999" `shouldBe` ["CARD BEGIN ZZZ-999", "unknown", "CARD END"]
