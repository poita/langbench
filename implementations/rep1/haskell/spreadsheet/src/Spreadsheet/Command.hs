{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Spreadsheet.Command
-- Description : The line-oriented command language of the CLI.
--
-- >>> runCommands ["set A1 2", "set A2 =A1*21", "get A2"]
-- ["42"]
module Spreadsheet.Command
  ( Command (..)
  , parseCommand
  , execute
  , runCommands
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Spreadsheet.Format (renderValue)
import Spreadsheet.Parser
import Spreadsheet.Sheet (Sheet)
import qualified Spreadsheet.Sheet as Sheet
import Spreadsheet.Types

-- | One line of input.
data Command
  = CmdSet CellRef Content
  | CmdGet CellRef
  | CmdClear CellRef
  | CmdDump
  deriving (Eq, Show)

-- | Parse a single command line (without its line terminator):
-- @set \<CELL\> \<content\>@, @get \<CELL\>@, @clear \<CELL\>@ or @dump@.
parseCommand :: Text -> Either ParseError Command
parseCommand line = case word of
  "dump" | T.null rest -> Right CmdDump
  "get" -> CmdGet <$> cell cellText
  "clear" -> CmdClear <$> cell cellText
  "set" -> CmdSet <$> cell cellText <*> parseContent (T.drop 1 afterCell)
  _ -> Left (ParseError ("unknown command: " ++ T.unpack line))
  where
    (word, rest) = T.break (== ' ') line
    (cellText, afterCell) = T.break (== ' ') (T.drop 1 rest)
    cell t = maybe (Left (ParseError ("invalid cell name: " ++ T.unpack t))) Right (parseCellRef t)

-- | Run one command against a sheet, returning the new sheet and the output
-- lines it produces (none for @set@ and @clear@, one for @get@ -- empty for an
-- empty cell -- and one per non-empty cell for @dump@).
execute :: Command -> Sheet -> (Sheet, [Text])
execute cmd sheet = case cmd of
  CmdSet ref c -> (Sheet.setContent ref c sheet, [])
  CmdClear ref -> (Sheet.clearCell ref sheet, [])
  CmdGet ref -> (sheet, [maybe T.empty renderValue (Sheet.lookupValue ref sheet)])
  CmdDump -> (sheet, [showCellRef ref <> " " <> renderValue v | (ref, v) <- Sheet.toList sheet])

-- | Run a whole script from an empty sheet and collect its output.
-- Lines that fail to parse are skipped.
runCommands :: [Text] -> [Text]
runCommands = go Sheet.empty
  where
    go _ [] = []
    go sh (l : ls) = case parseCommand l of
      Left _ -> go sh ls
      Right c -> let (sh', out) = execute c sh in out ++ go sh' ls
