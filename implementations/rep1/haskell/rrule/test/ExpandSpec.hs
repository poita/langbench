module ExpandSpec (spec) where

import RRule
import RRule.Calendar (fromCivil, weekdayIndex)
import Test.Hspec
import Test.QuickCheck

-- | Expand @rule@ from @start@, at most @n@ occurrences, as text.
run :: String -> String -> Int -> [String]
run start rule n = case (parseDateTime start, parseRule rule) of
  (Right s, Right r) -> map formatDateTime (take n (occurrences s r))
  (Left e, _) -> error e
  (_, Left e) -> error e

spec :: Spec
spec = do
  describe "specification examples" $ do
    it "last Friday of every second month" $
      run "19970902T090000" "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10" 100
        `shouldBe` words "19970926T090000 19971128T090000 19980130T090000 19980327T090000 19980529T090000 19980731T090000 19980925T090000 19981127T090000 19990129T090000 19990326T090000"
    it "WKST=SU weekly example" $
      run "19970902T090000" "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8" 100
        `shouldBe` words "19970902T090000 19970904T090000 19970916T090000 19970918T090000 19970930T090000 19971002T090000 19971014T090000 19971016T090000"
    it "WKST=MO weekly example" $
      run "19970902T090000" "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4" 4
        `shouldBe` words "19970902T090000 19970907T090000 19970916T090000 19970921T090000"
    it "yearly from 29 February only yields leap years" $
      run "20240229T120000" "FREQ=YEARLY;COUNT=3" 10
        `shouldBe` words "20240229T120000 20280229T120000 20320229T120000"
    it "monthly on the last day, with UNTIL inclusive" $
      run "20240131T000000" "FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000" 10
        `shouldBe` words "20240131T000000 20240229T000000 20240331T000000 20240430T000000"
    it "BYSETPOS selects the last weekday of the month" $
      run "20240301T080000" "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3" 10
        `shouldBe` words "20240329T080000 20240430T080000 20240531T080000"
    it "never-matching rules are empty" $
      run "20260101T000000" "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5" 10 `shouldBe` []
    it "BYWEEKNO=53 with BYDAY" $
      run "20200101T000000" "FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3" 10
        `shouldBe` words "20201228T000000 20261228T000000 20321227T000000"
    it "BYWEEKNO=53 without BYDAY (case b of week numbering)" $
      run "20110101T000000" "FREQ=YEARLY;BYWEEKNO=53;COUNT=4" 10
        `shouldBe` words "20110101T000000 20110102T000000 20151228T000000 20151229T000000"

  describe "limits" $ do
    it "stops at N" $ length (run "20000101T000000" "FREQ=DAILY" 7) `shouldBe` 7
    it "stops at COUNT" $ length (run "20000101T000000" "FREQ=DAILY;COUNT=4" 100) `shouldBe` 4
    it "COUNT does not include occurrences before DTSTART" $
      run "20240120T000000" "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=2" 10
        `shouldBe` words "20240205T000000 20240304T000000"
    it "UNTIL before DTSTART gives nothing" $
      run "20240120T000000" "FREQ=DAILY;UNTIL=20240101T000000" 10 `shouldBe` []
    it "stops after the year 9999" $
      run "99991230T010203" "FREQ=DAILY" 10 `shouldBe` words "99991230T010203 99991231T010203"
    it "keeps the time of day of DTSTART" $
      run "20240101T235959" "FREQ=DAILY;COUNT=2" 10 `shouldBe` words "20240101T235959 20240102T235959"

  describe "defaults and filters" $ do
    it "monthly from the 31st only yields 31-day months" $
      run "20240131T000000" "FREQ=MONTHLY;COUNT=4" 10
        `shouldBe` words "20240131T000000 20240331T000000 20240531T000000 20240731T000000"
    it "weekly defaults to the weekday of DTSTART" $
      run "20240103T000000" "FREQ=WEEKLY;COUNT=3" 10
        `shouldBe` words "20240103T000000 20240110T000000 20240117T000000"
    it "BYMONTH with ordinal BYDAY counts within each month" $
      run "20240101T000000" "FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=3" 10
        `shouldBe` words "20240108T000000 20240708T000000 20250113T000000"
    it "ordinal BYDAY without BYMONTH counts within the year" $
      run "20240101T000000" "FREQ=YEARLY;BYDAY=20MO;COUNT=2" 10
        `shouldBe` words "20240513T000000 20250519T000000"
    it "a non-existent ordinal contributes nothing" $
      run "20240101T000000" "FREQ=MONTHLY;BYDAY=5MO;COUNT=3" 10
        `shouldBe` words "20240129T000000 20240429T000000 20240729T000000"
    it "BYYEARDAY accepts negative values" $
      run "20240101T000000" "FREQ=YEARLY;BYYEARDAY=-1;COUNT=2" 10
        `shouldBe` words "20241231T000000 20251231T000000"
    it "BYSETPOS acts on the DTSTART default" $ do
      run "20240115T000000" "FREQ=MONTHLY;BYSETPOS=1;COUNT=2" 10 `shouldBe` words "20240115T000000 20240215T000000"
      run "20240115T000000" "FREQ=MONTHLY;BYSETPOS=2;COUNT=2" 10 `shouldBe` []

  describe "properties" $ do
    it "occurrences are strictly increasing and not before DTSTART" $
      property $ forAll genRule $ \(s, r) ->
        let occ = take 200 (occurrences s r)
         in conjoin
              [ and (zipWith (<) occ (drop 1 occ))
              , all (>= s) occ
              ]
    it "daily occurrences with interval k are k days apart" $
      property $ forAll (choose (1, 100)) $ \k ->
        let s = DateTime 2001 5 17 3 4 5
            occ = take 50 (occurrences s (defaultRule Daily) {ruleInterval = k})
            days (DateTime y m d _ _ _) = fromCivil y m d
         in and (zipWith (\a b -> days b - days a == k) occ (drop 1 occ))
    it "weekly BYDAY occurrences fall on the requested weekdays" $
      property $ forAll genWeekdays $ \wds ->
        let s = DateTime 2022 3 9 0 0 0
            r = (defaultRule Weekly) {ruleByDay = [ByDay Nothing w | w <- wds]}
            occ = take 60 (occurrences s r)
            wdOf (DateTime y m d _ _ _) = weekdayIndex (fromCivil y m d)
         in all ((`elem` map weekdayNumber wds) . wdOf) occ
    it "the same rule gives a prefix-consistent result for any limit" $
      property $ forAll genRule $ \(s, r) ->
        take 20 (occurrences s r) === take 20 (take 60 (occurrences s r))

genWeekdays :: Gen [Weekday]
genWeekdays = do
  ws <- sublistOf [minBound .. maxBound]
  if null ws then pure [Monday] else pure ws

genRule :: Gen (DateTime, Rule)
genRule = do
  y <- choose (1990, 2030)
  m <- choose (1, 12)
  d <- choose (1, 28)
  freq <- elements [Yearly, Monthly, Weekly, Daily]
  interval <- choose (1, 5)
  wkst <- elements [minBound .. maxBound]
  bymonth <- oneof [pure [], sublistOf [1 .. 12]]
  bymonthday <- oneof [pure [], sublistOf [-3, -1, 1, 15, 31]]
  byday <- if freq == Weekly || freq == Daily then fmap (map (ByDay Nothing)) (sublistOf [minBound .. maxBound]) else pure []
  setpos <- oneof [pure [], sublistOf [-1, 1, 2]]
  pure
    ( DateTime y m d 10 30 0
    , (defaultRule freq)
        { ruleInterval = interval
        , ruleWkst = wkst
        , ruleByMonth = bymonth
        , ruleByMonthDay = bymonthday
        , ruleByDay = byday
        , ruleBySetPos = setpos
        }
    )
