-- | Rendering of @layout.txt@, @report.txt@ and @error.txt@.
module Typeset.Output
  ( PageRecord (..)
  , Report (..)
  , renderLayout
  , renderReport
  , formatItem
  ) where

import Data.List (sortBy)
import Data.Ord (comparing)

import Typeset.Page
import Typeset.Settings

-- | A finished page: its label and every item of it.
data PageRecord = PageRecord
  { prLabel :: String
  , prItems :: [OutItem]
  }

-- | The counters of @report.txt@.
data Report = Report
  { rpFrontPages, rpBodyPages, rpLines, rpParagraphs, rpHeadings, rpTables :: !Int
  , rpFigures, rpFootnotes, rpSplitLines, rpHyphenated, rpOverfull :: !Int
  , rpEmergency, rpDemerits :: !Int
  }

-- | The sort key of an item: region, y, x, kind, text.
sortKey :: OutItem -> (Int, Int, Int, Int, String)
sortKey it = case it of
  OText r _ _ x y _ _ -> (fromEnum r, y, x, 0, formatItem it)
  ORule r x y _ _ -> (fromEnum r, y, x, 1, formatItem it)
  OBox r x y _ _ -> (fromEnum r, y, x, 2, formatItem it)

regionName :: Region -> String
regionName r = case r of
  RHeader -> "header"
  RFloat -> "float"
  RBody -> "body"
  RFootnote -> "footnote"
  RFooter -> "footer"

-- | The text of an item's line (without indentation).
formatItem :: OutItem -> String
formatItem it = case it of
  OText r f sz x y w s ->
    unwords ["text", regionName r, f, show sz, show x, show y, show w] ++ " \"" ++ concatMap esc s ++ "\""
  ORule r x y w t -> unwords ["rule", regionName r, show x, show y, show w, show t]
  OBox r x y w h -> unwords ["box", regionName r, show x, show y, show w, show h]
  where
    esc '\\' = "\\\\"
    esc '"' = "\\\""
    esc c = [c]

-- | Render @layout.txt@.
renderLayout :: Settings -> [PageRecord] -> String
renderLayout cfg pages = unlines (["layout 1", "pages " ++ show (length pages)] ++ concat (zipWith page [1 :: Int ..] pages))
  where
    page i p =
      unwords ["page", show i, prLabel p, show (pageWidth cfg), show (pageHeight cfg)
              , show (marginLeft cfg), show (marginTop cfg), show (bodyWidth cfg), show (bodyHeight cfg)]
      : map (("  " ++) . formatItem) (sortBy (comparing sortKey) (prItems p))

-- | Render @report.txt@.
renderReport :: Report -> String
renderReport r = unlines
  [ "report 1"
  , "pages " ++ show (rpFrontPages r + rpBodyPages r)
  , "front-pages " ++ show (rpFrontPages r)
  , "body-pages " ++ show (rpBodyPages r)
  , "lines " ++ show (rpLines r)
  , "paragraphs " ++ show (rpParagraphs r)
  , "headings " ++ show (rpHeadings r)
  , "tables " ++ show (rpTables r)
  , "figures " ++ show (rpFigures r)
  , "footnotes " ++ show (rpFootnotes r)
  , "footnote-split-lines " ++ show (rpSplitLines r)
  , "hyphenated-lines " ++ show (rpHyphenated r)
  , "overfull-lines " ++ show (rpOverfull r)
  , "emergency-lists " ++ show (rpEmergency r)
  , "total-demerits " ++ show (rpDemerits r)
  ]
