-- | Running headers and footers: placeholder substitution and the six slots.
module Typeset.Header
  ( PageInfo (..)
  , headerFooterItems
  ) where

import Data.Array (elems)

import Typeset.Font
import Typeset.HList
import Typeset.Hyphenation (Patterns)
import Typeset.Page
import Typeset.Settings
import Typeset.Syntax (Meta (..))

-- | What the placeholders of one page substitute to.
data PageInfo = PageInfo
  { piLabel :: String       -- ^ the page label (@12@ or @iv@)
  , piNumber :: !Int        -- ^ the label's numeric value (decides even/odd)
  , piPages :: !Int         -- ^ number of body pages
  , piChapter :: String
  , piSection :: String
  }

-- | Substitute the placeholders of a template.
substitute :: Meta -> PageInfo -> [Piece] -> String
substitute meta pg = concatMap one
  where
    one (PLit s) = s
    one (PHold p) = case p of
      PhPage -> piLabel pg
      PhPages -> show (piPages pg)
      PhTitle -> metaTitle meta
      PhAuthor -> metaAuthor meta
      PhDate -> metaDate meta
      PhChapter -> piChapter pg
      PhSection -> piSection pg

-- | The header and footer items of a page.
headerFooterItems :: Fonts -> Patterns -> Settings -> Meta -> PageInfo -> [OutItem]
headerFooterItems fonts pats cfg meta pg = concatMap slot specs
  where
    isEven = even (piNumber pg)
    face = resolveFace fonts (headerFont cfg) False False
    sz = headerSize cfg
    sty = Sty face sz 0
    bodyX = marginLeft cfg
    bw = bodyWidth cfg
    hp = HParams False pats 0 0 Nothing
    specs = [ (region, key, base, pos)
            | (region, kind, base) <- [(RHeader, "header", headerBaseline cfg), (RFooter, "footer", footerBaseline cfg)]
            , pos <- ["left", "center", "right"]
            , let key = kind ++ "-" ++ pos ]
    slot (region, key, base, pos) =
      let txt = substitute meta pg (slotTemplate cfg key isEven)
          items = filter visible (elems (buildList hp (litToks sty txt)))
          visible it = case it of IBox _ -> True; IGlue _ _ _ False -> True; _ -> False
          widths = [ case it of IBox b -> bxW b; IGlue w _ _ _ -> w; _ -> 0 | it <- items ]
          w = sum widths
          x0 = case pos of
            "left" -> bodyX
            "center" -> bodyX + ((bw - w) `div` 2)
            _ -> bodyX + bw - w
          place _ [] = []
          place x (it : rest) = case it of
            IBox b -> OText region (faceName face) sz x base (bxW b) (bxText b) : place (x + bxW b) rest
            IGlue gw _ _ _ -> place (x + gw) rest
            _ -> place x rest
      in if null items then [] else place x0 items
