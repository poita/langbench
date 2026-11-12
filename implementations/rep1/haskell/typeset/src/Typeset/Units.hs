-- | Exact integer arithmetic and numeral helpers shared by the whole engine.
--
-- Every quantity in the typesetter is an integer: lengths are millipoints,
-- glyph advances are thousandths of an em, and all division is /floor/
-- division (Haskell's 'div').
module Typeset.Units
  ( scale
  , stepUp
  , stepDown
  , roman
  , alphaLabel
  , cube100Div
  ) where

-- | Scale a glyph-space quantity (thousandths of an em) to millipoints at the
-- given size: @(u * size) \`div\` 1000@.
scale :: Int -> Int -> Int
scale u s = (u * s) `div` 1000
{-# INLINE scale #-}

-- | One size step larger: @(s * 6) \`div\` 5@.
stepUp :: Int -> Int
stepUp s = (s * 6) `div` 5

-- | One size step smaller: @(s * 5) \`div\` 6@.
stepDown :: Int -> Int
stepDown s = (s * 5) `div` 6

-- | Lowercase roman numerals by greedy subtraction.  The rule is applied
-- unchanged above 3999 (so 4000 is @mmmm@).  Non-positive input gives @""@.
roman :: Int -> String
roman = go table
  where
    table = [ (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c")
            , (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix")
            , (5, "v"), (4, "iv"), (1, "i") ]
    go _ n | n <= 0 = ""
    go [] _ = ""
    go ts@((v, s) : rest) n
      | n >= v = s ++ go ts (n - v)
      | otherwise = go rest n

-- | Bijective base-26 lowercase letters: 1 is @a@, 26 is @z@, 27 is @aa@.
alphaLabel :: Int -> String
alphaLabel n0 = reverse (go n0)
  where
    go n | n <= 0 = ""
         | otherwise = let m = (n - 1) `mod` 26
                       in toEnum (fromEnum 'a' + m) : go ((n - 1) `div` 26)

-- | @(100 * d^3) \`div\` y^3@ computed exactly for non-negative @d@ and
-- positive @y@, falling back to 'Integer' when the 64-bit product could
-- overflow.
cube100Div :: Int -> Int -> Int
cube100Div d y
  | d < 400000 && y < 2000000 = (100 * d * d * d) `div` (y * y * y)
  | otherwise =
      let d' = toInteger d
          y' = toInteger y
      in fromInteger ((100 * d' * d' * d') `div` (y' * y' * y'))
