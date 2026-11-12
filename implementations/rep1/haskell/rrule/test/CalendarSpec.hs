module CalendarSpec (spec) where

import RRule.Calendar
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "isLeapYear" $
    it "follows the Gregorian rule" $ do
      map isLeapYear [1900, 2000, 2023, 2024, 2100, 2400] `shouldBe` [False, True, False, True, False, True]

  describe "fromCivil / weekdayIndex" $ do
    it "anchors 0001-01-01 at day 0, a Monday" $ do
      fromCivil 1 1 1 `shouldBe` 0
      weekdayIndex (fromCivil 1 1 1) `shouldBe` 0
    it "knows 2000-01-01 was a Saturday" $
      weekdayIndex (fromCivil 2000 1 1) `shouldBe` 5
    it "knows 1997-09-02 was a Tuesday" $
      weekdayIndex (fromCivil 1997 9 2) `shouldBe` 1
    it "counts consecutive days" $
      fromCivil 2024 3 1 - fromCivil 2024 2 28 `shouldBe` 2

  describe "toCivil" $ do
    it "is the inverse of fromCivil for every day of years 1..9999 (sampled)" $
      property $ forAll genDate $ \(y, m, d) -> toCivil (fromCivil y m d) === (y, m, d)
    it "steps through consecutive days correctly" $
      property $ forAll (choose (-1000, 3700000)) $ \n ->
        let (y, m, d) = toCivil n
            next = toCivil (n + 1)
         in next === (if d < monthLength y m then (y, m, d + 1) else if m < 12 then (y, m + 1, 1) else (y + 1, 1, 1))
    it "handles the end of a 400-year cycle" $
      toCivil (fromCivil 400 12 31) `shouldBe` (400, 12, 31)

  describe "yearLength" $
    it "agrees with the day numbers of consecutive New Years" $
      property $ forAll (choose (1, 9998)) $ \y ->
        fromCivil (y + 1) 1 1 - fromCivil y 1 1 === yearLength y

  describe "weekInfo" $ do
    it "numbers weeks as ISO 8601 for WKST=MO" $ do
      weekInfo 0 2020 `shouldBe` WeekInfo (-2) 53 52
      weekInfo 0 2021 `shouldBe` WeekInfo 3 52 53
      weekInfo 0 2011 `shouldBe` WeekInfo 2 52 53
    it "always yields 52 or 53 weeks" $
      property $ forAll (choose (1000, 9999)) $ \y -> forAll (choose (0, 6)) $ \w ->
        wiWeeks (weekInfo w y) `elem` [52, 53]

genDate :: Gen (Int, Int, Int)
genDate = do
  y <- choose (1, 9999)
  m <- choose (1, 12)
  d <- choose (1, monthLength y m)
  pure (y, m, d)
