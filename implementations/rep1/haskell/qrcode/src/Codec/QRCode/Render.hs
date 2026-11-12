-- | Text rendering of symbols.
module Codec.QRCode.Render
  ( renderRows
  , renderSymbol
  ) where

import Data.ByteString.Builder (Builder, char7, intDec, string7)
import Data.Array.Unboxed ((!))

import Codec.QRCode.Types

-- | The rows of the symbol, one line each (@#@ dark, @.@ light), no quiet
-- zone; every row is followed by a newline.
renderRows :: QRCode -> Builder
renderRows qr = mconcat
  [ mconcat [char7 (if qrModules qr ! (y * n + x) then '#' else '.') | x <- [0 .. n - 1]] <> char7 '\n'
  | y <- [0 .. n - 1]
  ]
  where
    n = qrSize qr

-- | The CLI output block: a @version <v> mask <m>@ header, the rows and a
-- terminating empty line.
renderSymbol :: QRCode -> Builder
renderSymbol qr =
  string7 "version " <> intDec (qrVersion qr)
    <> string7 " mask " <> intDec (qrMask qr)
    <> char7 '\n' <> renderRows qr <> char7 '\n'
