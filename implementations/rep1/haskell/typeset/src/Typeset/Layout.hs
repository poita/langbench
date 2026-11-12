-- | Turning the block tree into vertical lists: the body (with figures and
-- footnotes set aside) and the table of contents.
module Typeset.Layout
  ( BodyLayout (..)
  , TocEntry (..)
  , layoutBody
  , layoutToc
  ) where

import Data.Array
import Data.List (intercalate)
import qualified Data.Map.Strict as M

import Typeset.Font
import Typeset.HList
import Typeset.Layout.Float
import Typeset.Layout.Monad
import Typeset.Layout.Table
import Typeset.Line
import Typeset.Settings
import Typeset.Syntax
import Typeset.Types
import Typeset.Units
import Typeset.Vertical

-- | The result of laying out the document body.
data BodyLayout = BodyLayout
  { blItems :: [VItem]
  , blFigures :: [FigBlock]               -- ^ in figure-number order
  , blNotes :: M.Map Int [SetLine]        -- ^ footnote lines by number
  , blStats :: Stats
  , blParagraphs :: Int
  , blHeadings :: Int
  , blTables :: Int
  }

rootCtx :: Settings -> TextCtx
rootCtx cfg = TextCtx
  { tcFamily = bodyFont cfg, tcBold = False, tcItalic = False
  , tcSize = bodySize cfg, tcLeading = leading cfg
  , tcLeft = marginLeft cfg, tcMeasure = bodyWidth cfg
  , tcAlign = bodyAlign cfg, tcFirstIndent = 0, tcHyphenate = hyphenate cfg }

clampMeasure :: Int -> Int
clampMeasure = max 1000

-- | Lay out the body of a document.
layoutBody :: Env -> [Block] -> BodyLayout
layoutBody env blocks =
  let (_, st) = runM env initState (walkBlocks 0 (rootCtx (envCfg env)) blocks)
  in BodyLayout
       { blItems = reverse (lsItems st)
       , blFigures = reverse (lsFigs st)
       , blNotes = lsNotes st
       , blStats = lsStats st
       , blParagraphs = lsParagraphs st
       , blHeadings = lsHeadings st
       , blTables = lsTables st }

walkBlocks :: Int -> TextCtx -> [Block] -> M ()
walkBlocks depth ctx = mapM_ (walkBlock depth ctx)

walkBlock :: Int -> TextCtx -> Block -> M ()
walkBlock depth ctx blk = do
  env <- ask
  let cfg = envCfg env
  case blk of
    BPara inl -> do
      ls <- textLines ctx { tcFirstIndent = parIndent cfg } [] inl
      items <- groupLines GOther (tcLeading ctx) ls
      modify (\s -> s { lsParagraphs = lsParagraphs s + 1 })
      leaf (parSpace cfg) (parSpace cfg) items
    BHeading lvl star inl -> walkHeading ctx lvl star inl
    BQuote bs -> do
      enterContainer (quoteSpace cfg)
      let qi = quoteIndent cfg
      walkBlocks depth ctx { tcLeft = tcLeft ctx + qi, tcMeasure = clampMeasure (tcMeasure ctx - 2 * qi) } bs
      leaveContainer (quoteSpace cfg)
    BGroup a bs -> do
      let ind = maybe 0 id (baIndent a)
          rind = maybe 0 id (baRightIndent a)
          ctx' = ctx { tcAlign = maybe (tcAlign ctx) id (baAlign a)
                     , tcSize = maybe (tcSize ctx) id (baSize a)
                     , tcLeading = maybe (tcLeading ctx) id (baLeading a)
                     , tcFamily = maybe (tcFamily ctx) id (baFont a)
                     , tcLeft = tcLeft ctx + ind
                     , tcMeasure = clampMeasure (tcMeasure ctx - (ind + rind)) }
      walkBlocks depth ctx' bs
    BList kind items -> do
      enterContainer (listSpace cfg)
      let li = listIndent cfg
          ctx' = ctx { tcLeft = tcLeft ctx + li, tcMeasure = clampMeasure (tcMeasure ctx - li) }
          depth' = depth + 1
          start = case kind of Ordered s -> s; Unordered -> 1
      mapM_ (\(idx, ListItem inl bs) -> do
               if idx > 0 then pendMax (listItemSpace cfg) else return ()
               ls <- textLines ctx' [] inl
               its <- groupLines GOther (tcLeading ctx') ls
               let mtext = markerText kind depth' (start + idx)
                   face = faceOf env ctx'
                   mw = textWidth face (tcSize ctx') mtext
                   mrun = Run (tcLeft ctx' - listMarkerGap cfg - mw) mtext (faceName face) (tcSize ctx') 0 mw
               leaf 0 0 (addMarker mrun its)
               walkBlocks depth' ctx' bs)
            (zip [0 ..] items)
      leaveContainer (listSpace cfg)
    BTable cols aligns elems -> do
      its <- layoutTable ctx cols aligns elems
      modify (\s -> s { lsTables = lsTables s + 1 })
      leaf (tableSpace cfg) (tableSpace cfg) its
    BPre ls -> do
      let pctx = ctx { tcFamily = preFont cfg, tcBold = False, tcItalic = False
                     , tcSize = preSize cfg, tcLeading = preLeading cfg
                     , tcLeft = tcLeft ctx + preIndent cfg
                     , tcMeasure = clampMeasure (tcMeasure ctx - preIndent cfg)
                     , tcAlign = AlignLeft, tcFirstIndent = 0 }
      sls <- mapM (preLine pctx) ls
      its <- groupLines GOther (preLeading cfg) sls
      leaf (preSpace cfg) (preSpace cfg) its
    BFig h mw cap -> do
      st <- get
      let idx = length (lsFigs st) + 1
      fb <- layoutFigure idx h mw cap
      modify (\s -> s { lsFigs = fb : lsFigs s })
      leaf 0 0 [VFloat idx]
    BRule -> leaf (ruleSpace cfg) (ruleSpace cfg) [VRule (tcLeft ctx) (tcMeasure ctx) (ruleThickness cfg)]
    BVSpace h -> addVSpace h
    BNewPage -> forceBreak

-- | Put the marker on the first line of an item.
addMarker :: Run -> [VItem] -> [VItem]
addMarker r (VLineI l : rest) = VLineI l { vlRuns = r : vlRuns l } : rest
addMarker _ its = its

-- | The text of a list marker.
markerText :: ListKind -> Int -> Int -> String
markerText kind depth n = case (kind, depth `mod` 3) of
  (Unordered, 1) -> "\8226"
  (Unordered, 2) -> "\8211"
  (Unordered, _) -> "*"
  (Ordered _, 1) -> show n ++ "."
  (Ordered _, 2) -> alphaLabel n ++ "."
  (Ordered _, _) -> roman n ++ "."

-- | One @\@pre@ line: a single box holding the whole line.
preLine :: TextCtx -> String -> M SetLine
preLine pctx s = do
  env <- ask
  let face = faceOf env pctx
      sty = Sty face (tcSize pctx) 0
      box = Box (textWidth face (tcSize pctx) s) s sty 0 0
      its = [ IBox box | not (null s) ]
            ++ [ IPenalty 10000 False Nothing, IGlue 0 0 0 True, IPenalty (-10000) False Nothing ]
      arr = listArray (0, length its - 1) its
      lc = LineCtx AlignLeft (tcLeft pctx) (tcMeasure pctx) 0 face (tcSize pctx)
      sl = setLine lc arr 0 (length its - 1)
  modify (\st -> st { lsStats = addStats (lsStats st) (Stats 0 0 (if slOverfull sl then 1 else 0) 0) })
  return sl

walkHeading :: TextCtx -> Int -> Bool -> Inline -> M ()
walkHeading ctx lvl star inl = do
  env <- ask
  let cfg = envCfg env
      numbered = not star && headingNumber cfg
  st <- get
  let counters = lsCounters st
      counters' = if numbered
                    then [ if i < lvl then c else if i == lvl then c + 1 else 0 | (i, c) <- zip [1 ..] counters ]
                    else counters
      numStr = if numbered then intercalate "." (map show (take lvl counters')) else ""
      hctx = ctx { tcFamily = headingFont cfg, tcBold = headingBold cfg, tcItalic = headingItalic cfg
                 , tcSize = headingSize cfg lvl, tcLeading = headingLeading cfg lvl
                 , tcAlign = headingAlign cfg, tcFirstIndent = 0 }
      sty = mkSty (envFonts env) (styleOf hctx)
      prefix = if numbered then litToks sty numStr ++ [RRigid (headingNumberGap cfg)] else []
  modify (\s -> s { lsCounters = counters', lsHeadings = lsHeadings s + 1 })
  if lvl == 1 && h1Newpage cfg then forceBreak else return ()
  ls <- textLines hctx prefix inl
  its <- groupLines GHeading (tcLeading hctx) ls
  let info = HeadInfo lvl star numStr (plainText inl)
      its' = case its of
        (VLineI l : rest) -> VLineI l { vlHead = Just info } : rest
        other -> other
  leaf (headingSpaceBefore cfg lvl) (headingSpaceAfter cfg lvl) its'

--------------------------------------------------------------------------
-- Table of contents

-- | An entry of the table of contents.
data TocEntry = TocEntry
  { teInfo :: HeadInfo
  , teLabel :: String    -- ^ the label of the page holding the heading
  }

-- | Lay out the table of contents' vertical list from its title and entries.
layoutToc :: Env -> String -> [TocEntry] -> ([VItem], Stats)
layoutToc env title entries =
  let (_, st) = runM env initState prog in (reverse (lsItems st), lsStats st)
  where
    cfg = envCfg env
    fonts = envFonts env
    prog = do
      let tctx = TextCtx
            { tcFamily = tocTitleFont cfg, tcBold = headingBold cfg, tcItalic = headingItalic cfg
            , tcSize = tocTitleSize cfg, tcLeading = headingLeading cfg 1
            , tcLeft = marginLeft cfg, tcMeasure = bodyWidth cfg
            , tcAlign = headingAlign cfg, tcFirstIndent = 0, tcHyphenate = hyphenate cfg }
          tsty = mkSty fonts (styleOf tctx)
      tls <- textLinesRaw tctx (litToks tsty title)
      titems <- groupLines GOther (tcLeading tctx) tls
      leaf 0 (tocTitleSpaceAfter cfg) titems
      mapM_ entry entries
    entry (TocEntry info label) = do
      let lvl = hiLevel info
          ectx = TextCtx
            { tcFamily = tocFont cfg, tcBold = False, tcItalic = False
            , tcSize = tocSize cfg, tcLeading = tocLeading cfg
            , tcLeft = marginLeft cfg + (lvl - 1) * tocIndent cfg
            , tcMeasure = clampMeasure (bodyWidth cfg - (lvl - 1) * tocIndent cfg - tocReserve cfg)
            , tcAlign = AlignLeft, tcFirstIndent = 0, tcHyphenate = hyphenate cfg }
          esty = mkSty fonts (styleOf ectx)
          prefix = if null (hiNumber info) then []
                   else litToks esty (hiNumber info) ++ [RRigid (tocNumberGap cfg)]
      ls <- textLinesRaw ectx (prefix ++ litToks esty (hiPlain info))
      let face = styFace esty
          sz = tocSize cfg
          lw = textWidth face sz label
          labelX = marginLeft cfg + bodyWidth cfg - lw
          lastL = last ls
          xFrom = slEndX lastL + tocLeaderGap cfg
          xTo = labelX - tocLeaderGap cfg
          unit = textWidth face sz (tocLeader cfg)
          k = max 0 ((xTo - xFrom) `div` unit)
          leader = [ Run (xTo - k * unit) (concat (replicate k (tocLeader cfg))) (faceName face) sz 0 (k * unit) | k > 0 ]
          extra = leader ++ [Run labelX label (faceName face) sz 0 lw]
          ls' = init ls ++ [lastL { slRuns = slRuns lastL ++ extra }]
      its <- groupLines GOther (tocLeading cfg) ls'
      leaf (tocEntrySpace cfg) (tocEntrySpace cfg) its

-- | Break and set a list given directly as tokens.
textLinesRaw :: TextCtx -> [RTok] -> M [SetLine]
textLinesRaw tc toks = do
  prep <- prepareText tc toks
  breakPrepared' tc prep (tcMeasure tc)
