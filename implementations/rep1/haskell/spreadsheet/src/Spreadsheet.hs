-- |
-- Module      : Spreadsheet
-- Description : An in-memory spreadsheet engine with incremental recalculation.
--
-- Cells hold numbers, strings or formulas.  Formulas reference other cells
-- and ranges and always reflect the current contents of the sheet, also after
-- cells are changed, cleared or made part of a reference cycle (which yields
-- @#CYCLE!@).
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > import qualified Spreadsheet as S
-- >
-- > main :: IO ()
-- > main = do
-- >   let Just a1 = S.parseCellRef "A1"
-- >       Just a2 = S.parseCellRef "A2"
-- >       Right sheet = S.setCell a1 "10" S.empty >>= S.setCell a2 "=A1*2"
-- >   print (fmap S.renderValue (S.lookupValue a2 sheet))   -- Just "20"
--
-- Modules:
--
-- * "Spreadsheet.Types": references, values, contents and syntax trees
-- * "Spreadsheet.Parser": parsing of formulas and cell contents
-- * "Spreadsheet.Eval": pure formula evaluation and dependency extraction
-- * "Spreadsheet.Format": number display (exact @%.10g@)
-- * "Spreadsheet.Graph": Tarjan's strongly connected components
-- * "Spreadsheet.Sheet": the sheet and incremental recalculation
-- * "Spreadsheet.Command": the @set@/@get@/@clear@/@dump@ command language
module Spreadsheet
  ( module Spreadsheet.Types
  , module Spreadsheet.Format
  , module Spreadsheet.Parser
  , module Spreadsheet.Sheet
  , module Spreadsheet.Command
  ) where

import Spreadsheet.Command
import Spreadsheet.Format
import Spreadsheet.Parser
import Spreadsheet.Sheet
import Spreadsheet.Types
