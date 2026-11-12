{-# LANGUAGE OverloadedStrings #-}
-- | The stdin document format: a JSON context, a @--@ line, then named
-- templates introduced by @=== name@ header lines.
module Template.Document
  ( Document (..)
  , parseDocument
  , renderDocument
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Template.Error
import Template.Eval
import Template.Json
import Template.Value

-- | A parsed input document.
data Document = Document
  { docContext   :: [(Text, Value)]   -- ^ the JSON members, in document order
  , docTemplates :: [(Text, Text)]    -- ^ name and body; the first is rendered
  }

-- | Split and parse a document.  The error is a human-readable message for
-- input that does not follow the format.
parseDocument :: Text -> Either String Document
parseDocument input = do
  let ls = T.splitOn "\n" input
      (jsonLines, afterJson) = break (== "--") ls
  case afterJson of
    [] -> Left "missing '--' line after the JSON context"
    (_ : tplLines) -> do
      ctx <- parseJson (T.intercalate "\n" jsonLines) >>= \v -> case v of
        VDict d -> Right (dictToList d)
        _ -> Left "the JSON context must be an object"
      let tpls = splitTemplates tplLines
      if null tpls then Left "no templates" else Right (Document ctx tpls)

splitTemplates :: [Text] -> [(Text, Text)]
splitTemplates ls = go (dropWhile (not . isHeader) ls)
  where
    isHeader l = "=== " `T.isPrefixOf` l
    go [] = []
    go (h : rest) =
      let (body, next) = break isHeader rest
          -- the last body loses the final LF, which shows up as a trailing ""
          body' = if null next && not (null body) && last body == "" then init body else body
      in (T.drop 4 h, T.intercalate "\n" body') : go next

-- | Run a whole document through the engine and produce exactly what the
-- command-line tool prints: the rendering and a newline, or @error: kind@.
renderDocument :: Text -> IO (Either String Text)
renderDocument input = case parseDocument input of
  Left e -> pure (Left e)
  Right (Document _ []) -> pure (Left "no templates")
  Right (Document ctx tpls@((mainName, _) : _)) -> do
    r <- renderIO ctx tpls mainName
    pure $ Right $ case r of
      Right out -> out <> "\n"
      Left k -> "error: " <> T.pack (errorKindName k) <> "\n"
