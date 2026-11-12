-- |
-- Module      : Fulltext.Porter
-- Description : The Porter (1980) stemming algorithm.
--
-- This is the algorithm of Martin Porter's reference implementation
-- @porter.c@, including its two departures from the published paper
-- (@BLI -> BLE@ and the extra @LOGI -> LOG@ rule in step 2).
--
-- A /word/ is a string of ASCII lower-case letters.  Words of one or two
-- letters are returned unchanged.
module Fulltext.Porter
  ( stem
  , measure
  ) where

import Data.List (isSuffixOf)

-- | Compute the Porter stem of a word made of the letters @a@–@z@.
--
-- >>> stem "relational"
-- "relat"
-- >>> stem "feed"
-- "feed"
stem :: String -> String
stem w
  | length w <= 2 = w
  | otherwise = step5b . step5a . step4 . step3 . step2 . step1c . step1b . step1a $ w

-- | The Porter /measure/ of a word: the @m@ in @[C](VC){m}[V]@.
measure :: String -> Int
measure s = length [() | (False, True) <- zip fs (drop 1 fs)]
  where fs = consonants s

-- | For each letter, is it a consonant?  @y@ is a consonant at the start of
-- the word and after a vowel, and a vowel after a consonant.
consonants :: String -> [Bool]
consonants = go False
  where
    go _ [] = []
    go prev (c : cs) = f : go f cs
      where
        f | c `elem` "aeiou" = False
          | c == 'y' = not prev
          | otherwise = True

hasVowel :: String -> Bool
hasVowel = not . and . consonants

-- | The stem ends with a double consonant.
doubleC :: String -> Bool
doubleC s = case reverse s of
  (a : b : _) -> a == b && last (consonants s)
  _ -> False

-- | The stem ends consonant-vowel-consonant, the last consonant not being
-- @w@, @x@ or @y@.
cvc :: String -> Bool
cvc s = case reverse (consonants s) of
  (True : False : True : _) -> last s `notElem` "wxy"
  _ -> False

stripSuffix :: String -> String -> Maybe String
stripSuffix suf w
  | suf `isSuffixOf` w = Just (take (length w - length suf) w)
  | otherwise = Nothing

-- | Select the first rule whose suffix matches; fire it only when its
-- condition holds on the remaining stem.
rules :: (String -> Bool) -> [(String, String)] -> String -> String
rules cond table w = go table
  where
    go [] = w
    go ((suf, rep) : rest) = case stripSuffix suf w of
      Nothing -> go rest
      Just s | cond s -> s ++ rep
             | otherwise -> w

step1a :: String -> String
step1a = rules (const True) [("sses", "ss"), ("ies", "i"), ("ss", "ss"), ("s", "")]

step1b :: String -> String
step1b w
  | Just s <- stripSuffix "eed" w = if measure s > 0 then s ++ "ee" else w
  | Just s <- stripSuffix "ed" w, hasVowel s = fixup s
  | Just s <- stripSuffix "ing" w, hasVowel s = fixup s
  | otherwise = w
  where
    fixup s
      | "at" `isSuffixOf` s = s ++ "e"
      | "bl" `isSuffixOf` s = s ++ "e"
      | "iz" `isSuffixOf` s = s ++ "e"
      | doubleC s = if last s `elem` "lsz" then s else init s
      | measure s == 1 && cvc s = s ++ "e"
      | otherwise = s

step1c :: String -> String
step1c w = case stripSuffix "y" w of
  Just s | hasVowel s -> s ++ "i"
  _ -> w

step2 :: String -> String
step2 = rules ((> 0) . measure)
  [ ("ational", "ate"), ("tional", "tion"), ("enci", "ence"), ("anci", "ance")
  , ("izer", "ize"), ("bli", "ble"), ("alli", "al"), ("entli", "ent")
  , ("eli", "e"), ("ousli", "ous"), ("ization", "ize"), ("ation", "ate")
  , ("ator", "ate"), ("alism", "al"), ("iveness", "ive"), ("fulness", "ful")
  , ("ousness", "ous"), ("aliti", "al"), ("iviti", "ive"), ("biliti", "ble")
  , ("logi", "log") ]

step3 :: String -> String
step3 = rules ((> 0) . measure)
  [ ("icate", "ic"), ("ative", ""), ("alize", "al"), ("iciti", "ic")
  , ("ical", "ic"), ("ful", ""), ("ness", "") ]

step4 :: String -> String
step4 w = rules cond table w
  where
    cond s = measure s > 1 && (not isIon || (not (null s) && last s `elem` "st"))
    isIon = "ion" `isSuffixOf` w
    table = [ (x, "") | x <-
      [ "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement"
      , "ment", "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize" ] ]

step5a :: String -> String
step5a w = case stripSuffix "e" w of
  Just s | m > 1 || (m == 1 && not (cvc s)) -> s
    where m = measure s
  _ -> w

step5b :: String -> String
step5b w
  | measure w > 1 && doubleC w && last w == 'l' = init w
  | otherwise = w
