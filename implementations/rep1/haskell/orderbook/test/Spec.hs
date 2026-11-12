{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy.Char8 as L
import Test.Hspec
import Test.QuickCheck

import OrderBook
import qualified OrderBook.Book as Book
import Reference (refRun)

-- | Run a textual input through the whole pipeline, returning output lines.
runText :: [C.ByteString] -> [String]
runText ls = lines . L.unpack . BB.toLazyByteString . processInput $
  C.unlines (C.pack (show (length ls)) : ls)

-- Generators ---------------------------------------------------------------

genCommands :: Gen [Command]
genCommands = do
  n <- choose (0, 120)
  go n (0 :: Int) []
  where
    go :: Int -> Int -> [Command] -> Gen [Command]
    go 0 _ acc = pure (reverse acc)
    go k next acc = do
      let known = map idOf [0 .. next - 1]
      c <- frequency
        [ (10, newLimit next)
        , (2, newMarket next)
        , (3, Cancel <$> anyId known)
        , (3, Replace <$> anyId known <*> price <*> qty)
        , (2, pure Snapshot) ]
      let next' = case c of
            Limit {}  -> next + 1
            Market {} -> next + 1
            _         -> next
      go (k - 1) next' (c : acc)
    idOf i = C.pack ("o" ++ show i)
    anyId known = oneof (pure "ghost" : map pure known)
    price = choose (95, 105)
    qty = frequency [(5, choose (1, 10)), (1, choose (1, 2000000000))]
    side = elements [Buy, Sell]
    tif = frequency [(6, pure GoodTillCancel), (2, pure ImmediateOrCancel), (2, pure FillOrKill)]
    newLimit n = Limit (idOf n) <$> side <*> price <*> qty <*> tif
    newMarket n = Market (idOf n) <$> side <*> qty

-- Specs --------------------------------------------------------------------

main :: IO ()
main = hspec $ do
  describe "parseCommand" $ do
    it "parses every command form" $ do
      parseCommand "LIMIT a BUY 10 5" `shouldBe` Just (Limit "a" Buy 10 5 GoodTillCancel)
      parseCommand "LIMIT a SELL 10 5 IOC" `shouldBe` Just (Limit "a" Sell 10 5 ImmediateOrCancel)
      parseCommand "LIMIT a SELL 10 5 FOK" `shouldBe` Just (Limit "a" Sell 10 5 FillOrKill)
      parseCommand "MARKET a BUY 7" `shouldBe` Just (Market "a" Buy 7)
      parseCommand "CANCEL a" `shouldBe` Just (Cancel "a")
      parseCommand "REPLACE a 3 4" `shouldBe` Just (Replace "a" 3 4)
      parseCommand "BOOK" `shouldBe` Just Snapshot
    it "treats keywords as ordinary ids by position" $
      parseCommand "LIMIT BUY SELL 1 1 IOC" `shouldBe` Just (Limit "BUY" Sell 1 1 ImmediateOrCancel)
    it "rejects garbage" $ parseCommand "NOPE" `shouldBe` Nothing
    it "honours the count line and a missing final newline" $
      parseCommands "1\nBOOK\nBOOK" `shouldBe` [Snapshot]

  describe "spec examples" $ do
    it "example 1: sweeping levels, price improvement" $
      runText [ "LIMIT s1 SELL 101 5", "LIMIT s2 SELL 103 5", "LIMIT s3 SELL 102 5"
              , "LIMIT s4 SELL 104 5", "LIMIT b1 BUY 103 12", "BOOK"
              , "LIMIT b2 BUY 110 1", "LIMIT b3 BUY 103 9", "BOOK" ]
        `shouldBe`
        [ "REST s1", "REST s2", "REST s3", "REST s4"
        , "TRADE b1 s1 101 5", "FILLED s1", "TRADE b1 s3 102 5", "FILLED s3"
        , "TRADE b1 s2 103 2", "FILLED b1", "ASK 103 3 1", "ASK 104 5 1", "--"
        , "TRADE b2 s2 103 1", "FILLED b2", "TRADE b3 s2 103 2", "FILLED s2"
        , "REST b3", "BID 103 7 1", "ASK 104 5 1", "--" ]
    it "example 2: IOC and rejects" $
      runText [ "LIMIT s1 SELL 100 5", "LIMIT s2 SELL 101 5", "LIMIT b1 BUY 100 8 IOC"
              , "BOOK", "LIMIT b2 BUY 99 8 IOC", "LIMIT b3 BUY 101 5 IOC", "BOOK"
              , "CANCEL b1", "REPLACE b1 100 1", "LIMIT s3 SELL 50 1 IOC", "BOOK" ]
        `shouldBe`
        [ "REST s1", "REST s2", "TRADE b1 s1 100 5", "FILLED s1", "CANCEL b1 3"
        , "ASK 101 5 1", "--", "CANCEL b2 8", "TRADE b3 s2 101 5", "FILLED s2"
        , "FILLED b3", "--", "REJECT b1", "REJECT b1", "CANCEL s3 1", "--" ]
    it "example 3: replace priority rules" $
      runText [ "LIMIT b1 BUY 100 10", "LIMIT s1 SELL 105 4", "LIMIT s2 SELL 106 4"
              , "REPLACE b1 105 6", "BOOK", "REPLACE b1 110 20", "BOOK"
              , "REPLACE b1 110 3", "CANCEL b1", "BOOK" ]
        `shouldBe`
        [ "REST b1", "REST s1", "REST s2", "TRADE b1 s1 105 4", "FILLED s1"
        , "REST b1", "BID 105 2 1", "ASK 106 4 1", "--"
        , "TRADE b1 s2 106 4", "FILLED s2", "REST b1", "BID 110 16 1", "--"
        , "REST b1", "CANCEL b1 3", "--" ]

  describe "engine details" $ do
    it "empty input yields no output" $ runText [] `shouldBe` []
    it "FOK rejects without changing the book" $
      runText ["LIMIT s1 SELL 10 5", "LIMIT f BUY 10 6 FOK", "BOOK"]
        `shouldBe` ["REST s1", "REJECT f", "ASK 10 5 1", "--"]
    it "FOK fills exactly the available quantity" $
      runText ["LIMIT s1 SELL 10 5", "LIMIT f BUY 10 5 FOK"]
        `shouldBe` ["REST s1", "TRADE f s1 10 5", "FILLED s1", "FILLED f"]
    it "market order against an empty side cancels whole" $
      runText ["MARKET m BUY 4"] `shouldBe` ["CANCEL m 4"]
    it "replace with lower quantity keeps FIFO position" $
      runText [ "LIMIT a BUY 10 5", "LIMIT b BUY 10 5", "REPLACE a 10 2"
              , "LIMIT s SELL 10 3" ]
        `shouldBe` [ "REST a", "REST b", "REST a", "TRADE s a 10 2", "FILLED a"
                   , "TRADE s b 10 1", "FILLED s" ]
    it "replace with higher quantity goes to the back" $
      runText [ "LIMIT a BUY 10 5", "LIMIT b BUY 10 5", "REPLACE a 10 6"
              , "LIMIT s SELL 10 1" ]
        `shouldBe` [ "REST a", "REST b", "REST a", "TRADE s b 10 1", "FILLED s" ]
    it "sums quantities beyond 2^32 with 64-bit integers" $
      runText [ "LIMIT a BUY 5 1000000000", "LIMIT b BUY 5 1000000000"
              , "LIMIT c BUY 5 1000000000", "LIMIT d BUY 5 1000000000"
              , "LIMIT e BUY 5 1000000000", "BOOK" ]
        `shouldBe` [ "REST a", "REST b", "REST c", "REST d", "REST e"
                   , "BID 5 5000000000 5", "--" ]
    it "ids equal to keywords are ordinary ids" $
      runText ["LIMIT BOOK BUY 1 1", "CANCEL BOOK"] `shouldBe` ["REST BOOK", "CANCEL BOOK 1"]

  describe "Book" $
    it "tracks size, totals and removal from the middle" $ do
      let b = foldl (\acc (i, q) -> Book.insertOrder Buy 10 i q acc) emptyBook
                [("a", 1), ("b", 2), ("c", 3)]
      Book.size b `shouldBe` 3
      Book.snapshot b `shouldBe` ([(10, 6, 3)], [])
      case Book.removeOrder "b" b of
        Nothing -> expectationFailure "b should rest"
        Just (_, q, b') -> do
          q `shouldBe` 2
          Book.snapshot b' `shouldBe` ([(10, 4, 2)], [])

  describe "properties" $ do
    it "matches the naive reference model" $
      withNumTests 2000 $ forAll genCommands $ \cmds ->
        run cmds === refRun cmds
    it "never leaves the book crossed and every command prints something" $
      withNumTests 500 $ forAll genCommands $ \cmds ->
        let evs = run cmds
            (bids, asks) = Book.snapshot (finalBook cmds)
        in length evs >= length cmds .&&.
           (case (bids, asks) of
              ((bp, _, _) : _, (ap, _, _) : _) -> bp < ap
              _ -> True)

finalBook :: [Command] -> Book
finalBook = foldl (\b c -> snd (execute c b)) emptyBook

