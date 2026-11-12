-- | The settings file: value types, the key table with defaults and ranges,
-- and the derived page geometry.
module Typeset.Settings
  ( Settings (..)
  , Piece (..)
  , Placeholder (..)
  , defaultSettings
  , parseSettings
  , parseLength
  , parseInteger
  , scanText
  , bodyWidth
  , bodyHeight
  , bodyBottom
  , headingSize
  , headingLeading
  , headingSpaceBefore
  , headingSpaceAfter
  , slotTemplate
  ) where

import Data.Char (isDigit)
import qualified Data.Map.Strict as M

import Typeset.Error
import Typeset.Types

-- | A named placeholder of a header/footer template.
data Placeholder = PhPage | PhPages | PhTitle | PhAuthor | PhDate | PhChapter | PhSection
  deriving (Eq, Show)

-- | A piece of a text setting: literal characters or a placeholder.
data Piece = PLit String | PHold Placeholder
  deriving (Eq, Show)

-- | Every layout setting.  Lengths are in millipoints.
data Settings = Settings
  { pageWidth, pageHeight, marginTop, marginBottom, marginLeft, marginRight :: !Int
  , headerBaseline, footerBaseline, pageStart :: !Int
  , bodyFont :: Family
  , bodySize, leading, lineSkip :: !Int
  , bodyAlign :: Align
  , parIndent, parSpace :: !Int
  , tolerance, linePenalty, hyphenPenalty, exHyphenPenalty :: !Int
  , adjDemerits, doubleHyphenDemerits, finalHyphenDemerits, raggedStretch :: !Int
  , hyphenate :: Bool
  , hyphenPatterns :: PatternName
  , headingFont :: Family
  , headingBold, headingItalic :: Bool
  , headingAlign :: Align
  , headingNumber :: Bool
  , headingNumberGap :: !Int
  , h1Newpage :: Bool
  , hSizes, hLeadings, hSpaceBefores, hSpaceAfters :: [Int]
  , listIndent, listMarkerGap, listSpace, listItemSpace, quoteIndent, quoteSpace :: !Int
  , preFont :: Family
  , preSize, preLeading, preIndent, preSpace :: !Int
  , tableColGap, tableRowSpace, tableRuleSpace, tableRuleThickness :: !Int
  , tableSpace, tableLeading, ruleThickness, ruleSpace :: !Int
  , footnoteFont :: Family
  , footnoteSize, footnoteLeading, footnoteIndent, footnoteMarkGap :: !Int
  , footnoteMarkSize, footnoteMarkRaise, footnoteItemSpace, footnoteRuleWidth :: !Int
  , footnoteRuleThickness, footnoteSpaceBefore, footnoteSpaceAfter, footnoteMinSplit :: !Int
  , footnoteMaxHeight :: !Int
  , markSize, markRaise :: !Int
  , figureWidth :: !Int
  , figureFrame :: Bool
  , figureCaptionFont :: Family
  , figureCaptionSize, figureCaptionLeading :: !Int
  , figureCaptionAlign :: Align
  , figureCaptionSpace :: !Int
  , figureCaptionPrefix :: String
  , figureCaptionGap, floatSpaceAfter, floatMinBody :: !Int
  , widows, orphans :: !Int
  , keepWithNext :: Bool
  , tocDepth :: !Int
  , tocFont :: Family
  , tocSize, tocLeading, tocIndent, tocNumberGap, tocReserve :: !Int
  , tocLeader :: String
  , tocLeaderGap, tocEntrySpace :: !Int
  , tocTitle :: String
  , tocTitleFont :: Family
  , tocTitleSize, tocTitleSpaceAfter :: !Int
  , headerFont :: Family
  , headerSize :: !Int
  , hfTexts :: M.Map String [Piece]
    -- ^ the twelve header/footer templates, by key (e.g. @header-left-even@)
  } deriving (Show)

-- | Width of the body rectangle.
bodyWidth :: Settings -> Int
bodyWidth s = pageWidth s - marginLeft s - marginRight s

-- | Height of the body rectangle.
bodyHeight :: Settings -> Int
bodyHeight s = pageHeight s - marginTop s - marginBottom s

-- | The y coordinate of the bottom of the body rectangle.
bodyBottom :: Settings -> Int
bodyBottom s = marginTop s + bodyHeight s

-- | Size of a heading level (1..4).
headingSize, headingLeading, headingSpaceBefore, headingSpaceAfter :: Settings -> Int -> Int
headingSize s n = hSizes s !! (n - 1)
headingLeading s n = hLeadings s !! (n - 1)
headingSpaceBefore s n = hSpaceBefores s !! (n - 1)
headingSpaceAfter s n = hSpaceAfters s !! (n - 1)

-- | The template of a header/footer slot, e.g. @slotTemplate s "header-left" True@
-- (the boolean selects the @-even@ variant).
slotTemplate :: Settings -> String -> Bool -> [Piece]
slotTemplate s key isEven =
  M.findWithDefault [] (if isEven then key ++ "-even" else key) (hfTexts s)

-- | All defaults.  Derived defaults (@footer-baseline@, @footnote-max-height@
-- and the @-even@ slots) are filled in after reading.
defaultSettings :: Settings
defaultSettings = Settings
  { pageWidth = 612000, pageHeight = 792000
  , marginTop = 72000, marginBottom = 72000, marginLeft = 72000, marginRight = 72000
  , headerBaseline = 36000, footerBaseline = 756000, pageStart = 1
  , bodyFont = Serif, bodySize = 10000, leading = 12000, lineSkip = 1000
  , bodyAlign = Justify, parIndent = 18000, parSpace = 0
  , tolerance = 1000, linePenalty = 10, hyphenPenalty = 50, exHyphenPenalty = 50
  , adjDemerits = 10000, doubleHyphenDemerits = 10000, finalHyphenDemerits = 5000
  , raggedStretch = 3, hyphenate = True, hyphenPatterns = English
  , headingFont = Sans, headingBold = True, headingItalic = False
  , headingAlign = AlignLeft, headingNumber = True, headingNumberGap = 6000
  , h1Newpage = False
  , hSizes = [20000, 14000, 12000, 11000]
  , hLeadings = [24000, 17000, 14000, 13000]
  , hSpaceBefores = [18000, 14000, 12000, 11000]
  , hSpaceAfters = [9000, 7000, 6000, 5000]
  , listIndent = 18000, listMarkerGap = 4000, listSpace = 6000, listItemSpace = 0
  , quoteIndent = 18000, quoteSpace = 6000
  , preFont = Mono, preSize = 9000, preLeading = 11000, preIndent = 0, preSpace = 6000
  , tableColGap = 8000, tableRowSpace = 2000, tableRuleSpace = 2000
  , tableRuleThickness = 400, tableSpace = 6000, tableLeading = 12000
  , ruleThickness = 500, ruleSpace = 6000
  , footnoteFont = Serif, footnoteSize = 8000, footnoteLeading = 10000
  , footnoteIndent = 10000, footnoteMarkGap = 2000, footnoteMarkSize = 6000
  , footnoteMarkRaise = 2000, footnoteItemSpace = 2000, footnoteRuleWidth = 120000
  , footnoteRuleThickness = 400, footnoteSpaceBefore = 6000, footnoteSpaceAfter = 3000
  , footnoteMinSplit = 1, footnoteMaxHeight = -1, markSize = 7000, markRaise = 3000
  , figureWidth = 0, figureFrame = True, figureCaptionFont = Serif
  , figureCaptionSize = 9000, figureCaptionLeading = 11000, figureCaptionAlign = AlignCenter
  , figureCaptionSpace = 4000, figureCaptionPrefix = "Figure", figureCaptionGap = 4000
  , floatSpaceAfter = 12000, floatMinBody = 24000
  , widows = 2, orphans = 2, keepWithNext = True
  , tocDepth = 2, tocFont = Serif, tocSize = 10000, tocLeading = 14000
  , tocIndent = 18000, tocNumberGap = 6000, tocReserve = 30000, tocLeader = "."
  , tocLeaderGap = 3000, tocEntrySpace = 0, tocTitle = "Contents"
  , tocTitleFont = Sans, tocTitleSize = 20000, tocTitleSpaceAfter = 12000
  , headerFont = Sans, headerSize = 9000
  , hfTexts = M.fromList [ (k, []) | k <- plainSlots ]
  }

plainSlots :: [String]
plainSlots = [ p ++ "-" ++ w | p <- ["header", "footer"], w <- ["left", "center", "right"] ]

--------------------------------------------------------------------------
-- Value parsers

-- | A failed value: error code and 0-based offset within the value.
type VErr = (ErrorCode, Int)

-- | A parsed value is a function updating the settings.
type Setter = String -> Either VErr (Settings -> Settings)

-- | Parse a length literal to millipoints.
parseLength :: String -> Maybe Int
parseLength s0 = do
  let (neg, s1) = case s0 of ('-' : r) -> (True, r); _ -> (False, s0)
      (whole, s2) = span isDigit s1
  if null whole then Nothing else Just ()
  (frac, s3) <- case s2 of
    ('.' : r) -> let (f, r') = span isDigit r
                 in if length f >= 1 && length f <= 3 then Just (f, r') else Nothing
    _ -> Just ("", s2)
  unit <- case s3 of
    "" -> Just 1
    "pt" -> Just 1000
    "mm" -> Just 2835
    "cm" -> Just 28350
    "in" -> Just 72000
    "pc" -> Just 12000
    _ -> Nothing
  let k = length frac
      p10 = 10 ^ k :: Integer
      fr = if null frac then 0 else read frac :: Integer
      v = ((read whole * p10 + fr) * unit) `div` p10
  return (fromInteger (if neg then negate v else v))

-- | Parse an integer literal.
parseInteger :: String -> Maybe Int
parseInteger s0 =
  let (neg, s1) = case s0 of ('-' : r) -> (True, r); _ -> (False, s0)
  in if not (null s1) && all isDigit s1 && length s1 < 15
       then Just (if neg then negate (read s1) else read s1)
       else Nothing

bad :: ErrorCode -> Either VErr a
bad c = Left (c, 0)

lenS :: Int -> Int -> (Int -> Settings -> Settings) -> Setter
lenS lo hi set v = case parseLength v of
  Nothing -> bad BadLength
  Just n | n < lo || n > hi -> bad BadValue
         | otherwise -> Right (set n)

intS :: Int -> Int -> (Int -> Settings -> Settings) -> Setter
intS lo hi set v = case parseInteger v of
  Nothing -> bad BadInteger
  Just n | n < lo || n > hi -> bad BadValue
         | otherwise -> Right (set n)

boolS :: (Bool -> Settings -> Settings) -> Setter
boolS set v = case v of
  "on" -> Right (set True)
  "off" -> Right (set False)
  _ -> bad BadBoolean

alignS :: (Align -> Settings -> Settings) -> Setter
alignS set v = case v of
  "justify" -> Right (set Justify)
  "left" -> Right (set AlignLeft)
  "right" -> Right (set AlignRight)
  "center" -> Right (set AlignCenter)
  _ -> bad BadEnum

famS :: (Family -> Settings -> Settings) -> Setter
famS set v = case v of
  "serif" -> Right (set Serif)
  "sans" -> Right (set Sans)
  "mono" -> Right (set Mono)
  _ -> bad UnknownFont

patS :: Setter
patS v = case v of
  "english" -> Right (\s -> s { hyphenPatterns = English })
  "minimal" -> Right (\s -> s { hyphenPatterns = Minimal })
  _ -> bad UnknownPatterns

-- | Scan a text value.  Returns the pieces, or the error code and the
-- 0-based offset of the offending character.
scanText :: String -> Either VErr [Piece]
scanText = go 0 "" []
  where
    flush lit acc = if null lit then acc else PLit (reverse lit) : acc
    go :: Int -> String -> [Piece] -> String -> Either VErr [Piece]
    go _ lit acc [] = Right (reverse (flush lit acc))
    go i lit acc (c : cs) = case c of
      '\\' -> case cs of
        (d : r) | d `elem` "{}\\" -> go (i + 2) (d : lit) acc r
        _ -> Left (BadEscape, i)
      '{' -> case break (== '}') cs of
        (name, '}' : r) -> case lookup name placeholders of
          Just p -> go (i + length name + 2) "" (PHold p : flush lit acc) r
          Nothing -> Left (UnknownPlaceholder, i)
        _ -> Left (UnknownPlaceholder, i)
      '}' -> Left (StrayBrace, i)
      _ -> go (i + 1) (c : lit) acc cs

placeholders :: [(String, Placeholder)]
placeholders =
  [ ("page", PhPage), ("pages", PhPages), ("title", PhTitle), ("author", PhAuthor)
  , ("date", PhDate), ("chapter", PhChapter), ("section", PhSection) ]

-- | A text value that must not contain placeholders; the result is checked
-- by the supplied predicate (failure is @bad-value@).
plainTextS :: (String -> Bool) -> (String -> Settings -> Settings) -> Setter
plainTextS okp set v = do
  ps <- scanText v
  case traverse lit ps of
    Nothing -> bad BadValue
    Just strs -> let str = concat strs
                 in if okp str then Right (set str) else bad BadValue
  where
    lit (PLit s) = Just s
    lit _ = Nothing

slotS :: String -> Setter
slotS key v = do
  ps <- scanText v
  Right (\s -> s { hfTexts = M.insert key ps (hfTexts s) })

--------------------------------------------------------------------------
-- The key table

table :: M.Map String Setter
table = M.fromList $
  [ ("page-width", lenS 36000 big (\n s -> s { pageWidth = n }))
  , ("page-height", lenS 36000 big (\n s -> s { pageHeight = n }))
  , ("margin-top", lenS 0 big (\n s -> s { marginTop = n }))
  , ("margin-bottom", lenS 0 big (\n s -> s { marginBottom = n }))
  , ("margin-left", lenS 0 big (\n s -> s { marginLeft = n }))
  , ("margin-right", lenS 0 big (\n s -> s { marginRight = n }))
  , ("header-baseline", lenS 0 big (\n s -> s { headerBaseline = n }))
  , ("footer-baseline", lenS 0 big (\n s -> s { footerBaseline = n }))
  , ("page-start", intS 1 3000 (\n s -> s { pageStart = n }))
  , ("body-font", famS (\f s -> s { bodyFont = f }))
  , ("body-size", lenS 1000 200000 (\n s -> s { bodySize = n }))
  , ("leading", lenS 1000 big (\n s -> s { leading = n }))
  , ("line-skip", lenS 0 big (\n s -> s { lineSkip = n }))
  , ("align", alignS (\a s -> s { bodyAlign = a }))
  , ("par-indent", lenS 0 big (\n s -> s { parIndent = n }))
  , ("par-space", lenS 0 big (\n s -> s { parSpace = n }))
  , ("tolerance", intS 0 10000 (\n s -> s { tolerance = n }))
  , ("line-penalty", intS 0 10000 (\n s -> s { linePenalty = n }))
  , ("hyphen-penalty", intS (-9999) 9999 (\n s -> s { hyphenPenalty = n }))
  , ("ex-hyphen-penalty", intS (-9999) 9999 (\n s -> s { exHyphenPenalty = n }))
  , ("adj-demerits", intS 0 1000000 (\n s -> s { adjDemerits = n }))
  , ("double-hyphen-demerits", intS 0 1000000 (\n s -> s { doubleHyphenDemerits = n }))
  , ("final-hyphen-demerits", intS 0 1000000 (\n s -> s { finalHyphenDemerits = n }))
  , ("ragged-stretch", intS 0 100 (\n s -> s { raggedStretch = n }))
  , ("hyphenate", boolS (\b s -> s { hyphenate = b }))
  , ("hyphen-patterns", patS)
  , ("heading-font", famS (\f s -> s { headingFont = f }))
  , ("heading-bold", boolS (\b s -> s { headingBold = b }))
  , ("heading-italic", boolS (\b s -> s { headingItalic = b }))
  , ("heading-align", alignS (\a s -> s { headingAlign = a }))
  , ("heading-number", boolS (\b s -> s { headingNumber = b }))
  , ("heading-number-gap", lenS 0 big (\n s -> s { headingNumberGap = n }))
  , ("h1-newpage", boolS (\b s -> s { h1Newpage = b }))
  , ("list-indent", lenS 0 big (\n s -> s { listIndent = n }))
  , ("list-marker-gap", lenS 0 big (\n s -> s { listMarkerGap = n }))
  , ("list-space", lenS 0 big (\n s -> s { listSpace = n }))
  , ("list-item-space", lenS 0 big (\n s -> s { listItemSpace = n }))
  , ("quote-indent", lenS 0 big (\n s -> s { quoteIndent = n }))
  , ("quote-space", lenS 0 big (\n s -> s { quoteSpace = n }))
  , ("pre-font", famS (\f s -> s { preFont = f }))
  , ("pre-size", lenS 1000 200000 (\n s -> s { preSize = n }))
  , ("pre-leading", lenS 1000 big (\n s -> s { preLeading = n }))
  , ("pre-indent", lenS 0 big (\n s -> s { preIndent = n }))
  , ("pre-space", lenS 0 big (\n s -> s { preSpace = n }))
  , ("table-col-gap", lenS 0 big (\n s -> s { tableColGap = n }))
  , ("table-row-space", lenS 0 big (\n s -> s { tableRowSpace = n }))
  , ("table-rule-space", lenS 0 big (\n s -> s { tableRuleSpace = n }))
  , ("table-rule-thickness", lenS 1 big (\n s -> s { tableRuleThickness = n }))
  , ("table-space", lenS 0 big (\n s -> s { tableSpace = n }))
  , ("table-leading", lenS 1000 big (\n s -> s { tableLeading = n }))
  , ("rule-thickness", lenS 1 big (\n s -> s { ruleThickness = n }))
  , ("rule-space", lenS 0 big (\n s -> s { ruleSpace = n }))
  , ("footnote-font", famS (\f s -> s { footnoteFont = f }))
  , ("footnote-size", lenS 1000 200000 (\n s -> s { footnoteSize = n }))
  , ("footnote-leading", lenS 1000 big (\n s -> s { footnoteLeading = n }))
  , ("footnote-indent", lenS 0 big (\n s -> s { footnoteIndent = n }))
  , ("footnote-mark-gap", lenS 0 big (\n s -> s { footnoteMarkGap = n }))
  , ("footnote-mark-size", lenS 1000 200000 (\n s -> s { footnoteMarkSize = n }))
  , ("footnote-mark-raise", lenS 0 big (\n s -> s { footnoteMarkRaise = n }))
  , ("footnote-item-space", lenS 0 big (\n s -> s { footnoteItemSpace = n }))
  , ("footnote-rule-width", lenS 0 big (\n s -> s { footnoteRuleWidth = n }))
  , ("footnote-rule-thickness", lenS 1 big (\n s -> s { footnoteRuleThickness = n }))
  , ("footnote-space-before", lenS 0 big (\n s -> s { footnoteSpaceBefore = n }))
  , ("footnote-space-after", lenS 0 big (\n s -> s { footnoteSpaceAfter = n }))
  , ("footnote-min-split", intS 1 100 (\n s -> s { footnoteMinSplit = n }))
  , ("footnote-max-height", lenS 1000 big (\n s -> s { footnoteMaxHeight = n }))
  , ("mark-size", lenS 1000 200000 (\n s -> s { markSize = n }))
  , ("mark-raise", lenS 0 big (\n s -> s { markRaise = n }))
  , ("figure-width", lenS 0 big (\n s -> s { figureWidth = n }))
  , ("figure-frame", boolS (\b s -> s { figureFrame = b }))
  , ("figure-caption-font", famS (\f s -> s { figureCaptionFont = f }))
  , ("figure-caption-size", lenS 1000 200000 (\n s -> s { figureCaptionSize = n }))
  , ("figure-caption-leading", lenS 1000 big (\n s -> s { figureCaptionLeading = n }))
  , ("figure-caption-align", alignS (\a s -> s { figureCaptionAlign = a }))
  , ("figure-caption-space", lenS 0 big (\n s -> s { figureCaptionSpace = n }))
  , ("figure-caption-prefix", plainTextS (const True) (\t s -> s { figureCaptionPrefix = t }))
  , ("figure-caption-gap", lenS 0 big (\n s -> s { figureCaptionGap = n }))
  , ("float-space-after", lenS 0 big (\n s -> s { floatSpaceAfter = n }))
  , ("float-min-body", lenS 0 big (\n s -> s { floatMinBody = n }))
  , ("widows", intS 1 20 (\n s -> s { widows = n }))
  , ("orphans", intS 1 20 (\n s -> s { orphans = n }))
  , ("keep-with-next", boolS (\b s -> s { keepWithNext = b }))
  , ("toc-depth", intS 0 4 (\n s -> s { tocDepth = n }))
  , ("toc-font", famS (\f s -> s { tocFont = f }))
  , ("toc-size", lenS 1000 200000 (\n s -> s { tocSize = n }))
  , ("toc-leading", lenS 1000 big (\n s -> s { tocLeading = n }))
  , ("toc-indent", lenS 0 big (\n s -> s { tocIndent = n }))
  , ("toc-number-gap", lenS 0 big (\n s -> s { tocNumberGap = n }))
  , ("toc-reserve", lenS 0 big (\n s -> s { tocReserve = n }))
  , ("toc-leader", plainTextS (\t -> let l = length t in l >= 1 && l <= 8 && ' ' `notElem` t)
                              (\t s -> s { tocLeader = t }))
  , ("toc-leader-gap", lenS 0 big (\n s -> s { tocLeaderGap = n }))
  , ("toc-entry-space", lenS 0 big (\n s -> s { tocEntrySpace = n }))
  , ("toc-title", plainTextS (const True) (\t s -> s { tocTitle = t }))
  , ("toc-title-font", famS (\f s -> s { tocTitleFont = f }))
  , ("toc-title-size", lenS 1000 200000 (\n s -> s { tocTitleSize = n }))
  , ("toc-title-space-after", lenS 0 big (\n s -> s { tocTitleSpaceAfter = n }))
  , ("header-font", famS (\f s -> s { headerFont = f }))
  , ("header-size", lenS 1000 200000 (\n s -> s { headerSize = n }))
  ]
  ++ [ (k, slotS k) | p <- ["header", "footer"], w <- ["left", "center", "right"]
                    , let b = p ++ "-" ++ w, k <- [b, b ++ "-even"] ]
  ++ concat
  [ [ ("h" ++ d ++ "-size", lenS 1000 200000 (setN (\v s -> s { hSizes = v (hSizes s) })))
    , ("h" ++ d ++ "-leading", lenS 1000 big (setN (\v s -> s { hLeadings = v (hLeadings s) })))
    , ("h" ++ d ++ "-space-before", lenS 0 big (setN (\v s -> s { hSpaceBefores = v (hSpaceBefores s) })))
    , ("h" ++ d ++ "-space-after", lenS 0 big (setN (\v s -> s { hSpaceAfters = v (hSpaceAfters s) })))
    ]
  | n <- [1 .. 4 :: Int], let d = show n
  , let setN upd x = upd (replaceAt (n - 1) x) ]
  where
    big = maxBound `div` 4
    replaceAt i x xs = take i xs ++ [x] ++ drop (i + 1) xs

--------------------------------------------------------------------------
-- The file

-- | Parse and validate a settings file.  The result is the resolved
-- settings, or the first error.
parseSettings :: String -> Either Error Settings
parseSettings txt = go 1 (lines txt) defaultSettings M.empty []
  where
    err ln col code = Left (Error SettingsFile ln col code)
    go :: Int -> [String] -> Settings -> M.Map String () -> [(Int, Int)] -> Either Error Settings
    go _ [] st assigned geo = finish st assigned geo
    go ln (l : ls) st assigned geo =
      let lead = length (takeWhile (`elem` " \t") l)
          body = drop lead l
      in case body of
        [] -> go (ln + 1) ls st assigned geo
        ('#' : _) -> go (ln + 1) ls st assigned geo
        _ ->
          let (key, r1) = span isKeyChar body
              r2 = dropWhile (`elem` " \t") r1
          in case r2 of
            ('=' : r3) | not (null key) ->
              let keyCol = lead + 1
                  v0 = dropWhile (`elem` " \t") r3
                  valCol = if null v0 then length l + 1 else length l - length v0 + 1
                  value = trim' v0
              in case M.lookup key table of
                Nothing -> err ln keyCol UnknownSetting
                Just setter
                  | M.member key assigned -> err ln keyCol DuplicateSetting
                  | otherwise -> case setter value of
                      Left (code, off) -> err ln (valCol + off) code
                      Right f ->
                        let geo' = if key `elem` geoKeys then (ln, valCol) : geo else geo
                        in go (ln + 1) ls (f st) (M.insert key () assigned) geo'
            _ -> err ln (lead + 1) BadSyntax
    isKeyChar c = (c >= 'a' && c <= 'z') || isDigit c || c == '-'
    trim' = reverse . dropWhile (`elem` " \t") . reverse
    geoKeys = ["page-width", "page-height", "margin-top", "margin-bottom", "margin-left", "margin-right"]
    finish st assigned geo =
      let bw = bodyWidth st
          bh = bodyHeight st
      in if bw < 36000 || bh < 36000
           then case geo of
                  ((ln, col) : _) -> err ln col BadValue
                  [] -> err 0 0 BadValue
           else Right (resolve st assigned)
    resolve st assigned =
      let fb = if M.member "footer-baseline" assigned then footerBaseline st else pageHeight st - 36000
          fm = if M.member "footnote-max-height" assigned then footnoteMaxHeight st else bodyHeight st `div` 2
          texts = hfTexts st
          withEven = foldr (\k m -> if M.member (k ++ "-even") m then m
                                    else M.insert (k ++ "-even") (M.findWithDefault [] k m) m)
                           texts plainSlots
      in st { footerBaseline = fb, footnoteMaxHeight = fm, hfTexts = withEven }
