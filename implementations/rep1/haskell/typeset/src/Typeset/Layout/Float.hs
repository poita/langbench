-- | Figure blocks: the frame and the caption set beneath it.
module Typeset.Layout.Float
  ( layoutFigure
  ) where

import Typeset.HList
import Typeset.Layout.Monad
import Typeset.Line
import Typeset.Settings
import Typeset.Syntax
import Typeset.Vertical

-- | Lay out a figure block relative to its own top.  The arguments are the
-- figure's number, its height, an optional width, and the caption.
layoutFigure :: Int -> Int -> Maybe Int -> Inline -> M FigBlock
layoutFigure number height mw caption = do
  env <- ask
  let cfg = envCfg env
      w0 = maybe (figureWidth cfg) id mw
      fw = if w0 > 0 then w0 else bodyWidth cfg
      fx = marginLeft cfg + ((bodyWidth cfg - fw) `div` 2)
      ctx = TextCtx
        { tcFamily = figureCaptionFont cfg, tcBold = False, tcItalic = False
        , tcSize = figureCaptionSize cfg, tcLeading = figureCaptionLeading cfg
        , tcLeft = fx, tcMeasure = fw, tcAlign = figureCaptionAlign cfg
        , tcFirstIndent = 0, tcHyphenate = hyphenate cfg }
      sty = mkSty (envFonts env) (styleOf ctx)
      prefix = figureCaptionPrefix cfg
      prefixToks = if null prefix then [] else litToks sty prefix ++ [RGlueFix sty]
      toks = prefixToks ++ litToks sty (show number ++ ".") ++ [RRigid (figureCaptionGap cfg)]
  ls <- textLines ctx toks caption
  let captionTop = height + figureCaptionSpace cfg
      place _ [] = []
      place Nothing (l : rest) = let b = captionTop + slAscent l in (b, l) : place (Just (b, slDepth l)) rest
      place (Just (pb, pd)) (l : rest) =
        let b = pb + max (figureCaptionLeading cfg) (pd + lineSkip cfg + slAscent l)
        in (b, l) : place (Just (b, slDepth l)) rest
      placed = place Nothing ls
      total = case reverse placed of
        ((b, l) : _) -> b + slDepth l
        [] -> captionTop
  return FigBlock
    { fbHeight = total
    , fbFrame = if figureFrame cfg then Just (fx, fw, height) else Nothing
    , fbLines = placed }
