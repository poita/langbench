-- | The line-oriented query format of the command-line tool.
--
-- Each query line is @\<ecl\> \<mask\> \<text\>@ with @ecl@ one of
-- @L M Q H@, @mask@ a digit @0..7@ or @auto@, and the text being everything
-- after the second space.
module Codec.QRCode.Query
  ( Query (..)
  , parseQuery
  , processLine
  , processInput
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder (Builder)

import Codec.QRCode (encode)
import Codec.QRCode.Render (renderSymbol)
import Codec.QRCode.Types

-- | A parsed query.
data Query = Query
  { queryEcl     :: Ecl
  , queryMask    :: MaskChoice
  , queryPayload :: B.ByteString
  }
  deriving (Eq, Show)

-- | Parse one query line (without its newline).
parseQuery :: B.ByteString -> Either String Query
parseQuery line = do
  let (eclTok, r1) = BC.break (== ' ') line
      (maskTok, r2) = BC.break (== ' ') (B.drop 1 r1)
      text = B.drop 1 r2
  ecl <- case BC.unpack eclTok of
    "L" -> Right L
    "M" -> Right M
    "Q" -> Right Q
    "H" -> Right H
    _ -> Left ("bad error correction level: " ++ show (BC.unpack eclTok))
  mask <- case BC.unpack maskTok of
    "auto" -> Right AutoMask
    [d] | d >= '0' && d <= '7' -> Right (FixedMask (fromEnum d - fromEnum '0'))
    _ -> Left ("bad mask: " ++ show (BC.unpack maskTok))
  if B.null r2 || B.null text
    then Left "missing text"
    else Right (Query ecl mask text)

-- | Parse and encode one line, producing the output block for it.
processLine :: B.ByteString -> Either String Builder
processLine line = do
  Query ecl mask text <- parseQuery line
  case encode ecl mask text of
    Left err -> Left (show err)
    Right qr -> Right (renderSymbol qr)

-- | Process a whole input: one result per non-empty line, in order.
processInput :: B.ByteString -> [Either String Builder]
processInput = map processLine . filter (not . B.null) . BC.split '\n'
