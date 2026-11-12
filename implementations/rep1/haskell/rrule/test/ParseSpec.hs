module ParseSpec (spec) where

import RRule
import RRule.Batch (processInput)
import RRule.Parse (splitOn)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "parseDateTime" $ do
    it "parses a valid date-time" $
      parseDateTime "19970902T090507" `shouldBe` Right (DateTime 1997 9 2 9 5 7)
    it "rejects non-existent dates" $ do
      parseDateTime "20230229T000000" `shouldSatisfy` isLeft'
      parseDateTime "20240431T000000" `shouldSatisfy` isLeft'
      parseDateTime "20240101T240000" `shouldSatisfy` isLeft'
    it "rejects malformed text" $ do
      parseDateTime "2024-01-01" `shouldSatisfy` isLeft'
      parseDateTime "20240101X000000" `shouldSatisfy` isLeft'
    it "round-trips through formatDateTime" $
      property $ forAll (choose (1000, 9999)) $ \y ->
        let t = DateTime y 12 31 23 59 59 in parseDateTime (formatDateTime t) === Right t

  describe "parseRule" $ do
    it "reads every kind of part" $
      parseRule "FREQ=YEARLY;INTERVAL=2;COUNT=5;WKST=SU;BYMONTH=1,7;BYMONTHDAY=-1,3;BYYEARDAY=100;BYWEEKNO=-1;BYDAY=2MO,-1FR;BYSETPOS=1"
        `shouldBe` Right
          (defaultRule Yearly)
            { ruleInterval = 2
            , ruleCount = Just 5
            , ruleWkst = Sunday
            , ruleByMonth = [1, 7]
            , ruleByMonthDay = [-1, 3]
            , ruleByYearDay = [100]
            , ruleByWeekNo = [-1]
            , ruleByDay = [ByDay (Just 2) Monday, ByDay (Just (-1)) Friday]
            , ruleBySetPos = [1]
            }
    it "accepts parts in any order, with UNTIL" $
      parseRule "UNTIL=20240430T000000;FREQ=DAILY"
        `shouldBe` Right (defaultRule Daily) {ruleUntil = Just (DateTime 2024 4 30 0 0 0)}
    it "reads plain weekday codes" $
      parseRule "FREQ=WEEKLY;BYDAY=TU,TH"
        `shouldBe` Right (defaultRule Weekly) {ruleByDay = [ByDay Nothing Tuesday, ByDay Nothing Thursday]}
    it "requires FREQ" $ parseRule "COUNT=3" `shouldSatisfy` isLeft'
    it "rejects unknown parts and values" $ do
      parseRule "FREQ=HOURLY" `shouldSatisfy` isLeft'
      parseRule "FREQ=DAILY;BYFOO=1" `shouldSatisfy` isLeft'
      parseRule "FREQ=DAILY;COUNT=x" `shouldSatisfy` isLeft'
      parseRule "FREQ=WEEKLY;BYDAY=XX" `shouldSatisfy` isLeft'

  describe "splitOn" $
    it "keeps empty fields" $ splitOn ',' "a,,b," `shouldBe` ["a", "", "b", ""]

  describe "processInput" $ do
    it "produces one line per input line" $
      render "20240229T120000 FREQ=YEARLY;COUNT=3 10\n20260101T000000 FREQ=DAILY;COUNT=2 10"
        `shouldBe` Right "20240229T120000 20280229T120000 20320229T120000\n20260101T000000 20260102T000000\n"
    it "prints an empty line when there are no occurrences" $
      render "20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30 10\n" `shouldBe` Right "\n"
    it "honours the line limit N" $
      render "20260101T000000 FREQ=DAILY 1\n" `shouldBe` Right "20260101T000000\n"
    it "reports malformed lines" $
      render "nonsense\n" `shouldSatisfy` isLeft'
  where
    isLeft' = either (const True) (const False)
    render = fmap (BL.unpack . B.toLazyByteString) . processInput . BL.pack
