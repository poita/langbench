-- | Page breaking: break legality, the per-page cut scan, footnote
-- placement and splitting, and floating figures.
module Typeset.Page
  ( Region (..)
  , OutItem (..)
  , PageBody (..)
  , paginate
  ) where

import Data.Array
import qualified Data.Array.Unboxed as U
import qualified Data.Map.Strict as M

import Typeset.Font (Face (..), Fonts, resolveFace, textWidth)
import Typeset.Line
import Typeset.Settings
import Typeset.Vertical

-- | The region of an output item (in output sort order).
data Region = RHeader | RFloat | RBody | RFootnote | RFooter
  deriving (Eq, Ord, Show, Enum)

-- | One output item of a page.
data OutItem
  = OText Region String Int Int Int Int String   -- ^ region face size x y width text
  | ORule Region Int Int Int Int                 -- ^ region x y width thickness
  | OBox Region Int Int Int Int                  -- ^ region x y width height
  deriving (Show)

-- | A paginated page (without its header and footer).
data PageBody = PageBody
  { pbItems :: [OutItem]
  , pbLines :: !Int
  , pbHeads :: [HeadInfo]
  }

-- | Footnote lines grouped by footnote.
data FGroup = FGroup
  { fgNum :: !Int
  , fgLines :: [SetLine]
  , fgMark :: !Bool
  }

-- | State of a footnote stack while lines are added (cursor, fresh, prev
-- baseline, prev depth, line count).
data Stack = Stack !Int !Bool !Int !Int !Int

emptyStack :: Stack
emptyStack = Stack 0 True 0 0 0

stackHeight :: Stack -> Int
stackHeight (Stack c _ _ _ _) = c

stackLines :: Stack -> Int
stackLines (Stack _ _ _ _ n) = n

-- | Add one line to a stack.
stackLine :: Int -> Int -> Stack -> SetLine -> Stack
stackLine ldg skip (Stack c fresh pb pd n) l =
  let base = if fresh then c + slAscent l else pb + max ldg (pd + skip + slAscent l)
  in Stack (base + slDepth l) False base (slDepth l) (n + 1)

-- | Start a new group: item space (unless first) and fresh.
stackGroupStart :: Int -> Stack -> Stack
stackGroupStart itemSpace st@(Stack c _ pb pd n)
  | n == 0 = st
  | otherwise = Stack (c + itemSpace) True pb pd n

stackGroup :: Settings -> Stack -> [SetLine] -> Stack
stackGroup cfg st ls =
  foldl' (stackLine (footnoteLeading cfg) (lineSkip cfg)) (stackGroupStart (footnoteItemSpace cfg) st) ls

-- | Area taken by a footnote stack.
fnArea :: Settings -> Stack -> Int
fnArea cfg st
  | stackLines st == 0 = 0
  | otherwise = footnoteSpaceBefore cfg + footnoteRuleThickness cfg + footnoteSpaceAfter cfg + stackHeight st

-- | Paginate a vertical list.  Returns the pages and the number of footnote
-- lines carried from one page to the next.
paginate :: Fonts -> Settings -> Array Int FigBlock -> M.Map Int [SetLine] -> [VItem] -> ([PageBody], Int)
paginate fonts cfg figs notes items = go 0 [] [] 0 []
  where
    n = length items
    v = listArray (0, max 0 (n - 1)) items :: Array Int VItem
    bodyH = bodyHeight cfg
    bodyY = marginTop cfg
    bodyX = marginLeft cfg
    bodyBot = bodyBottom cfg
    maxFn = footnoteMaxHeight cfg
    isGlue j = case v ! j of VGlue _ -> True; VForce -> True; _ -> False
    isForce j = case v ! j of VForce -> True; _ -> False
    legal = legalBreaks cfg n v
    figArr = figs

    skipStart i | i < n && isGlue i = skipStart (i + 1)
                | otherwise = i

    go :: Int -> [Int] -> [FGroup] -> Int -> [PageBody] -> ([PageBody], Int)
    go i0 queue carried splitTot acc =
      let i = skipStart i0
      in if i >= n && null queue && null carried
           then (reverse acc, splitTot)
           else
             let -- step 1: figures
                 (taken, zone) = takeFigures (i < n) queue
                 queue1 = drop (length taken) queue
                 bodyTop = bodyY + zone
                 goal = bodyH - zone
                 -- step 2/3: cut
                 cut = if i >= n then n else chooseCut i goal carried
                 -- step 4: body items (trailing glue dropped)
                 lastNon = lastNonGlue i (cut - 1)
                 bodyIdx = [i .. lastNon]
                 (bodyOut, bodyUsed, bodyLines, heads) = placeBody bodyTop bodyIdx
                 refs = [ k | j <- bodyIdx, VLineI l <- [v ! j], k <- vlNotes l ]
                 cands = carried ++ [ FGroup k (M.findWithDefault [] k notes) True | k <- refs ]
                 avail = goal - bodyUsed - footnoteSpaceBefore cfg - footnoteRuleThickness cfg
                         - footnoteSpaceAfter cfg
                 bodyEmpty = null bodyIdx
                 (placedGroups, carriedNext) = splitFootnotes cands avail bodyEmpty
                 carriedCount = sum (map (length . fgLines) carriedNext)
                 (fnOut, fnLines) = placeFootnotes placedGroups
                 (figOut, figLines) = placeFigures bodyY taken
                 newFigs = [ k | j <- bodyIdx, VFloat k <- [v ! j] ]
                 page = PageBody (figOut ++ bodyOut ++ fnOut) (figLines + bodyLines + fnLines) heads
             in go cut (queue1 ++ newFigs) carriedNext (splitTot + carriedCount) (page : acc)

    lastNonGlue i j | j >= i && (case v ! j of VGlue _ -> True; _ -> False) = lastNonGlue i (j - 1)
                    | otherwise = j

    -- figures ---------------------------------------------------------
    takeFigures bodyLeft queue = loop 0 0 queue []
      where
        loop _ zoneH [] acc = (reverse acc, zoneH)
        loop k zoneH (f : fs) acc =
          let h = fbHeight (figArr ! f)
              zoneNext = zoneH + h + floatSpaceAfter cfg
              ok | bodyLeft = bodyH - zoneNext >= floatMinBody cfg
                 | otherwise = k == (0 :: Int) || zoneNext <= bodyH
          in if ok then loop (k + 1) zoneNext fs (f : acc) else (reverse acc, zoneH)

    placeFigures y0 taken = foldl' one ([], 0) (zip taken (scanl (\y f -> y + fbHeight (figArr ! f) + floatSpaceAfter cfg) y0 taken))
      where
        one (out, cnt) (f, y) =
          let fb = figArr ! f
              frame = case fbFrame fb of
                Just (x, w, h) -> [OBox RFloat x y w h]
                Nothing -> []
              txt = concat [ runsOut RFloat (y + off) (slRuns sl) | (off, sl) <- fbLines fb ]
          in (out ++ frame ++ txt, cnt + length (fbLines fb))

    -- the cut scan ----------------------------------------------------
    chooseCut i goal carried = scan (i + 1) st0 fnSt0 0 Nothing
      where
        st0 = (0 :: Int, True, 0 :: Int, 0 :: Int, 0 :: Int)   -- cursor, fresh, prevBase, prevDepth, usedCursor
        fnSt0 = foldl' (stackGroup cfg) emptyStack (map fgLines carried)
        scan j (cur, fresh, pb, pd, usedC) fnSt _ best
          | j > n = finish best
          | isForce (j - 1) = j - 1
          | otherwise =
              let it = v ! (j - 1)
                  (cur', fresh', pb', pd', usedC') = case it of
                    VLineI l ->
                      let base = if fresh then cur + vlAscent l
                                 else pb + max (vlLeading l) (pd + lineSkip cfg + vlAscent l)
                          c2 = base + vlDepth l
                      in (c2, False, base, vlDepth l, c2)
                    VGlue h -> (cur + h, True, pb, pd, usedC)
                    VRule _ _ t -> (cur + t, True, pb, pd, cur + t)
                    VRow h _ _ -> (cur + h, True, pb, pd, cur + h)
                    VFloat _ -> (cur, fresh, pb, pd, cur)
                    VForce -> (cur, fresh, pb, pd, cur)
                  fnSt' = case it of
                    VLineI l -> foldl' (\s k -> stackGroup cfg s (M.findWithDefault [] k notes)) fnSt (vlNotes l)
                    _ -> fnSt
                  used = usedC' + min (fnArea cfg fnSt') maxFn
              in if used > goal then finish best
                 else scan (j + 1) (cur', fresh', pb', pd', usedC') fnSt' (0 :: Int)
                        (if legal U.! j then Just j else best)
        finish (Just j) = j
        finish Nothing = firstLegal (i + 1)
        firstLegal j | j >= n = n
                     | legal U.! j = j
                     | otherwise = firstLegal (j + 1)

    -- body placement --------------------------------------------------
    placeBody bodyTop idxs = (concat (reverse outs), used, cnt, heads)
      where
        (outs, final, _, _, _, cnt, heads) = foldl' step ([], bodyTop, True, 0, 0, 0 :: Int, []) idxs
        used = if null idxs then 0 else final - bodyTop
        step (os, cur, fresh, pb, pd, c, hs) j = case v ! j of
          VLineI l ->
            let base = if fresh then cur + vlAscent l
                       else pb + max (vlLeading l) (pd + lineSkip cfg + vlAscent l)
                o = runsOut RBody base (vlRuns l)
            in (o : os, base + vlDepth l, False, base, vlDepth l, c + 1, hs ++ maybe [] (: []) (vlHead l))
          VGlue h -> (os, cur + h, True, pb, pd, c, hs)
          VRule x w t -> ([ORule RBody x cur w t] : os, cur + t, True, pb, pd, c, hs)
          VRow h cells k ->
            let o = concat [ runsOut RBody (cur + off) rs | (off, rs) <- cells ]
            in (o : os, cur + h, True, pb, pd, c + k, hs)
          VFloat _ -> (os, cur, fresh, pb, pd, c, hs)
          VForce -> (os, cur, fresh, pb, pd, c, hs)

    runsOut region base = map (\r -> OText region (runFace r) (runSize r) (runX r) (base - runRaise r) (runWidth r) (runText r))

    -- footnotes --------------------------------------------------------
    -- Choose how many candidate lines fit; returns the placed groups and the
    -- groups carried to the next page.
    splitFootnotes cands avail bodyEmpty = (placed, carriedG)
      where
        flat = [ (gi, l) | (gi, g) <- zip [0 :: Int ..] cands, l <- fgLines g ]
        total = length flat
        p0 = length (takeWhile (<= avail) (stackHeights flat))
        p1 = minSplit p0
        p | bodyEmpty && p1 == 0 && total > 0 = 1
          | otherwise = p1
        placedFlat = take p flat
        placedIds = map fst placedFlat
        placed = regroup placedFlat (\_ g -> fgMark g)
        carriedG = regroup (drop p flat) (\gi g -> fgMark g && gi `notElem` placedIds)
        regroup part markOf =
          [ FGroup (fgNum g) ls (markOf gi g)
          | (gi, g) <- zip [0 :: Int ..] cands
          , let ls = [ l | (gi', l) <- part, gi' == gi ]
          , not (null ls) ]
        -- a prefix ending inside a group must leave footnote-min-split lines of it
        minSplit k
          | k <= 0 || k >= total = k
          | fst (flat !! (k - 1)) /= fst (flat !! k) = k
          | otherwise =
              let g = fst (flat !! k)
                  start = length (takeWhile ((/= g) . fst) flat)
              in if k - start < footnoteMinSplit cfg && start > 0 then start else k

    -- stack height after each successive line
    stackHeights = go emptyStack (-1)
      where
        go _ _ [] = []
        go s pg ((gi, l) : r) =
          let s0 = if gi /= pg then stackGroupStart (footnoteItemSpace cfg) s else s
              s1 = stackLine (footnoteLeading cfg) (lineSkip cfg) s0 l
          in stackHeight s1 : go s1 gi r

    placeFootnotes [] = ([], 0)
    placeFootnotes groups =
      let st = foldl' (stackGroup cfg) emptyStack (map fgLines groups)
          hfn = stackHeight st
          ruleTop = bodyBot - hfn - footnoteSpaceAfter cfg - footnoteRuleThickness cfg
          stackTop = ruleTop + footnoteRuleThickness cfg + footnoteSpaceAfter cfg
          rule = ORule RFootnote bodyX ruleTop (footnoteRuleWidth cfg) (footnoteRuleThickness cfg)
          markFace = resolveFace fonts (footnoteFont cfg) False False
          (outs, _, _, _, _, _) = foldl' groupStep ([], stackTop, True, 0, 0, True) groups
          groupStep (os, cur, fresh, pb, pd, firstG) g =
            let (cur0, fresh0) = if firstG then (cur, fresh) else (cur + footnoteItemSpace cfg, True)
                (os', cur', fresh', pb', pd', _) = foldl' lineStep (os, cur0, fresh0, pb, pd, True) (fgLines g)
                lineStep (o, c, f, pb0, pd0, firstL) l =
                  let base = if f then c + slAscent l else pb0 + max (footnoteLeading cfg) (pd0 + lineSkip cfg + slAscent l)
                      o1 = reverse (runsOut RFootnote base (slRuns l)) ++ o
                      mk = if firstL && fgMark g
                             then let txt = show (fgNum g)
                                      w = textWidth markFace (footnoteMarkSize cfg) txt
                                  in [OText RFootnote (faceName markFace) (footnoteMarkSize cfg)
                                        (bodyX + footnoteIndent cfg - footnoteMarkGap cfg - w)
                                        (base - footnoteMarkRaise cfg) w txt]
                             else []
                  in (mk ++ o1, base + slDepth l, False, base, slDepth l, False)
            in (os', cur', fresh', pb', pd', False)
          nLines = sum (map (length . fgLines) groups)
      in (rule : reverse outs, nLines)

-- | The legality of each break position @0..n@.
legalBreaks :: Settings -> Int -> Array Int VItem -> U.UArray Int Bool
legalBreaks cfg n v = U.listArray (0, n) [ ok j | j <- [0 .. n] ]
  where
    ok j
      | j == 0 = False
      | j == n = True
      | otherwise = lineOk j && not (inKeep U.! j)
    lineOk j = case v ! j of
      VLineI l -> case vlKind l of
        GHeading -> vlIndex l == 1
        GOther -> vlIndex l <= 1 || (vlIndex l - 1 >= orphans cfg && vlGroupSize l - vlIndex l + 1 >= widows cfg)
      _ -> True
    inKeep :: U.UArray Int Bool
    inKeep
      | not (keepWithNext cfg) = U.listArray (0, n) (replicate (n + 1) False)
      | otherwise = U.accumArray (\_ b -> b) False (0, n)
          [ (p, True) | j <- [0 .. n - 1], isHeadEnd (v ! j), p <- keepRun (j + 1) ]
    isHeadEnd it = case it of
      VLineI l -> vlKind l == GHeading && vlIndex l == vlGroupSize l
      _ -> False
    keepRun s = go s
      where
        go j | j >= n = [ p | p <- [s .. n - 1] ]
             | skippable (v ! j) = go (j + 1)
             | otherwise = [s .. j]
        skippable it = case it of VGlue _ -> True; VFloat _ -> True; _ -> False
