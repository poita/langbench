-- | Table layout: column widths from cell measurements, rows, rules.
module Typeset.Layout.Table
  ( layoutTable
  , columnWidths
  ) where

import Data.List (transpose)
import Data.Maybe (listToMaybe)

import Typeset.Break
import Typeset.HList
import Typeset.Layout.Monad
import Typeset.Line
import Typeset.Settings
import Typeset.Syntax
import Typeset.Types
import Typeset.Vertical

-- | Column widths from the per-column natural and minimum widths.
columnWidths :: Int -> [Int] -> [Int] -> [Int]
columnWidths avail nats mins
  | sum nats <= avail = nats
  | sum mins >= avail = mins
  | otherwise = zipWith (\n c -> n - c) nats incs
  where
    d = sum nats - avail
    diffs = zipWith (-) nats mins
    s = sum diffs
    ps = scanl1 (+) diffs
    cs = map (\p -> (d * p) `div` s) ps
    incs = zipWith (-) cs (0 : cs)

alignOf :: ColAlign -> Align
alignOf a = case a of
  ColLeft -> AlignLeft
  ColRight -> AlignRight
  ColCenter -> AlignCenter

-- | Lay out a table in the given block context, giving its vertical items.
layoutTable :: TextCtx -> Int -> [ColAlign] -> [TableElem] -> M [VItem]
layoutTable ctx cols aligns elems = do
  env <- ask
  let cfg = envCfg env
      cellCtx a = ctx { tcFamily = tcFamily ctx, tcBold = False, tcItalic = False
                      , tcLeading = tableLeading cfg, tcAlign = alignOf a, tcFirstIndent = 0 }
      rowsIn = [ cs | TRow cs <- elems ]
  -- build every cell's list once
  prepRows <- mapM (\cs -> mapM (\(a, inl) -> do
                         let cc = cellCtx a
                             toks = flatten (envFonts env) cfg (styleOf cc) inl
                         p <- prepareText cc toks
                         return (cc, p))
                       (zip aligns cs))
                   rowsIn
  let cols' = transpose prepRows
      nats = [ maximum (0 : [ naturalWidth p | (_, p) <- c ]) | c <- cols' ]
      mins = [ maximum (0 : [ minLineWidth p | (_, p) <- c ]) | c <- cols' ]
      nats' = if null cols' then replicate cols 0 else nats
      mins' = if null cols' then replicate cols 0 else mins
      avail = max 0 (tcMeasure ctx - (cols - 1) * tableColGap cfg)
      ws = columnWidths avail nats' mins'
      tw = sum ws + (cols - 1) * tableColGap cfg
      xs = scanl (\x w -> x + w + tableColGap cfg) (tcLeft ctx) ws
  -- break every row
  rowItems <- mapM (\cells -> do
      ls <- mapM (\((cc, p), x, w) -> breakPrepared' cc { tcLeft = x, tcMeasure = w } p w)
                 (zip3 cells xs ws)
      let aRow = maximum (0 : [ maybe 0 slAscent (listToMaybe l) | l <- ls ])
          nRow = maximum (1 : map length ls)
          dRow = maximum (0 : [ maybe 0 slDepth (lastMay l) | l <- ls ])
          tl = tableLeading cfg
          h = aRow + (nRow - 1) * tl + dRow
          cellLines = [ (aRow + (k - 1) * tl, slRuns sl) | l <- ls, (k, sl) <- zip [1 ..] l ]
      return (VRow h cellLines (length cellLines)))
    prepRows
  -- interleave rows and rules
  let build _ _ [] _ = []
      build prevRow first (e : rest) rows = case e of
        TRow _ -> case rows of
          (r : rs) -> [ VGlue (tableRowSpace cfg) | prevRow ] ++ [r] ++ build True False rest rs
          [] -> []
        THRule ->
          [ VGlue (tableRuleSpace cfg) | not first ]
          ++ [ VRule (tcLeft ctx) tw (tableRuleThickness cfg) ]
          ++ [ VGlue (tableRuleSpace cfg) | not (null rest) ]
          ++ build False False rest rows
  return (build False True elems rowItems)

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)
