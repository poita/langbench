-- | Setting a line: glue distribution, horizontal placement, output runs and
-- vertical metrics.
module Typeset.Line
  ( Run (..)
  , SetLine (..)
  , LineCtx (..)
  , setLine
  , setLines
  ) where

import Data.Array

import Typeset.Font (Face (..))
import Typeset.HList
import Typeset.Types
import Typeset.Units

-- | A placed run of text (one @text@ item of the output).
data Run = Run
  { runX :: !Int
  , runText :: String
  , runFace :: String
  , runSize :: !Int
  , runRaise :: !Int
  , runWidth :: !Int
  } deriving (Show)

-- | A set line.
data SetLine = SetLine
  { slRuns :: [Run]
  , slAscent :: !Int
  , slDepth :: !Int
  , slEndX :: !Int          -- ^ x after the last item (start x for an empty line)
  , slNotes :: [Int]        -- ^ footnote numbers referenced, in order
  , slOverfull :: !Bool
  , slHyphenated :: !Bool   -- ^ ends at a breakpoint with pre-break text
  , slLeft :: !Int          -- ^ left edge of the line
  } deriving (Show)

-- | What 'setLine' needs to know about the list's context.
data LineCtx = LineCtx
  { lcAlign :: Align
  , lcLeft :: !Int
  , lcMeasure :: !Int
  , lcFirstIndent :: !Int
  , lcFace :: Face        -- ^ initial face (used when a line has no boxes)
  , lcSize :: !Int
  }

-- | Set the line between breakpoints @a < b@ of the item array.
setLine :: LineCtx -> Array Int Item -> Int -> Int -> SetLine
setLine ctx items a b = SetLine runs asc dep endX notes overfull hyph leftLine
  where
    firstLine = a == 0
    leftLine = lcLeft ctx + (if firstLine then lcFirstIndent ctx else 0)
    l = lcMeasure ctx - (if firstLine then lcFirstIndent ctx else 0)
    startIdx = skipGlue from
    skipGlue i | i >= b = b
               | isGlue (items ! i) = skipGlue (i + 1)
               | otherwise = i
    from = if a == 0 then 0 else a + 1
    body = [ items ! i | i <- [startIdx .. b - 1] ]
    pre = case items ! b of
      IPenalty _ _ (Just bx) -> Just bx
      _ -> Nothing
    full = body ++ maybe [] (\bx -> [IBox bx]) pre
    isGlue it = case it of IGlue {} -> True; _ -> False
    hyph = case pre of Just _ -> True; Nothing -> False
    (w, y, z, inf) = foldl' acc (0, 0, 0, False) full
    acc (w', y', z', i') it = case it of
      IBox bx -> (w' + bxW bx, y', z', i')
      IRigidBox rw -> (w' + rw, y', z', i')
      IGlue gw gy gz gi -> (w' + gw, y' + gy, z' + gz, i' || gi)
      IPenalty {} -> (w', y', z', i')
    e = l - w
    -- set widths of the glues, in order
    glueWidths = distribute
    gluesIn = [ (gw, gy, gz, gi) | IGlue gw gy gz gi <- full ]
    distribute
      | inf = [ if gi then 0 else gw | (gw, _, _, gi) <- gluesIn ]
      | lcAlign ctx /= Justify = [ gw | (gw, _, _, _) <- gluesIn ]
      | e == 0 = naturals
      | e > 0 && y == 0 = naturals
      | e < 0 && z == 0 = naturals
      | e > 0 = spread e y [ gy | (_, gy, _, _) <- gluesIn ]
      | negate e <= z = spread e z [ gz | (_, _, gz, _) <- gluesIn ]
      | otherwise = [ gw - gz | (gw, _, gz, _) <- gluesIn ]
    naturals = [ gw | (gw, _, _, _) <- gluesIn ]
    spread total t weights =
      let ps = scanl1 (+) weights
          cs = map (\pi' -> (total * pi') `div` t) ps
          incs = zipWith (-) cs (0 : cs)
      in zipWith (+) naturals incs
    wSet = sum [ case it of
                   IBox bx -> bxW bx
                   IRigidBox rw -> rw
                   _ -> 0
               | it <- full ] + sum glueWidths
    startX = case lcAlign ctx of
      AlignRight -> leftLine + l - wSet
      AlignCenter -> leftLine + ((l - wSet) `div` 2)
      _ -> leftLine
    endX = startX + wSet
    overfull = wSet > l
    -- place items, merging runs
    (runs, notes) = place startX (glueWidths) full [] Nothing []
    place :: Int -> [Int] -> [Item] -> [Run] -> Maybe (Int, Run) -> [Int] -> ([Run], [Int])
    place _ _ [] done cur ns = (reverse (flushCur cur done), reverse ns)
    place x gws (it : rest) done cur ns = case it of
      IPenalty {} -> place x gws rest done cur ns
      IGlue {} -> case gws of
        (gw : gws') -> place (x + gw) gws' rest (flushCur cur done) Nothing ns
        [] -> place x gws rest (flushCur cur done) Nothing ns
      IRigidBox rw -> place (x + rw) gws rest (flushCur cur done) Nothing ns
      IBox bx ->
        let ns' = if bxNote bx > 0 then bxNote bx : ns else ns
        in case cur of
          Just (fid, r) | fid == bxFrag bx ->
            place (x + bxW bx) gws rest done
                  (Just (fid, r { runText = runText r ++ bxText bx, runWidth = runWidth r + bxW bx })) ns'
          _ -> let Sty f sz rz = bxSty bx
                   r = Run x (bxText bx) (faceName f) sz rz (bxW bx)
               in place (x + bxW bx) gws rest (flushCur cur done) (Just (bxFrag bx, r)) ns'
    flushCur Nothing done = done
    flushCur (Just (_, r)) done = r : done
    boxes = [ bx | IBox bx <- full ]
    (asc, dep)
      | null boxes = ( scale (faceAscent (lcFace ctx)) (lcSize ctx), scale (faceDescent (lcFace ctx)) (lcSize ctx) )
      | otherwise =
          ( maximum [ scale (faceAscent f) sz + rz | bx <- boxes, let Sty f sz rz = bxSty bx ]
          , maximum [ max 0 (scale (faceDescent f) sz - rz) | bx <- boxes, let Sty f sz rz = bxSty bx ] )

-- | Set all lines of a breaking.
setLines :: LineCtx -> Array Int Item -> [Int] -> [SetLine]
setLines ctx items bs = zipWith (setLine ctx items) (0 : bs) bs
