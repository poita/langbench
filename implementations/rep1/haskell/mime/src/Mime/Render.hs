-- | The text dump format: escaping, per-message report, summary line.
module Mime.Render
  ( esc
  , quote
  , renderMessage
  , renderSummaryLine
  , renderSummary
  , attachmentPath
  ) where

import qualified Data.ByteString as B
import Data.Char (ord)
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Numeric (showHex)

import Mime.Bytes (adler32Hex)
import Mime.Date
import Mime.Header
import Mime.Message
import Mime.Address
import Mime.Part

-- | Escape a string for the dump.
esc :: String -> String
esc = concatMap f
  where
    f '\\' = "\\\\"
    f '\n' = "\\n"
    f '\r' = "\\r"
    f '\t' = "\\t"
    f '"' = "\\\""
    f c
      | o < 0x20 || o == 0x7F || (o >= 0x80 && o <= 0x9F) =
          "\\x" ++ (if o < 16 then "0" else "") ++ showHex o ""
      | otherwise = [c]
      where
        o = ord c

-- | Escape and surround with double quotes.
quote :: String -> String
quote s = "\"" ++ esc s ++ "\""

pad :: Int -> Int -> String
pad n v = let s = show v in replicate (n - length s) '0' ++ s

-- | Relative path of an attachment file.
attachmentPath :: Int -> Part -> String
attachmentPath no p = "parts/" ++ pad 4 no ++ "/" ++ pad 3 (partIndex p) ++ ".bin"

-- | The per-message line of @summary.txt@.
renderSummaryLine :: Int -> String -> Message -> String
renderSummaryLine no src m =
  unwords
    [ pad 4 no
    , "source=" ++ quote src
    , "bytes=" ++ show (msgSize m)
    , "parts=" ++ show (length (messageParts m))
    , "attachments=" ++ show (length (msgAttachments m))
    , "text=" ++ idx (msgTextBody m)
    , "html=" ++ idx (msgHtmlBody m)
    ]
  where
    idx = maybe "-" (show . partIndex)

-- | The whole @summary.txt@ given its per-message lines.
renderSummary :: [String] -> String
renderSummary ls = unlines (("messages " ++ show (length ls)) : ls)

-- | The @messages/NNNN.txt@ dump.
renderMessage :: Int -> String -> Message -> String
renderMessage no src m =
  intercalate "\n" (map unlines sections)
  where
    sections =
      [ ["[message]", "id " ++ pad 4 no, "source " ++ quote src]
      , "[headers]" : [fieldNameKey f ++ ": " ++ quote (fieldValue f) | f <- msgHeaders m]
      , "[addresses]" : addresses
      , "[date]" : dateLines
      , "[structure]" : map structureLine (structure (msgRoot m))
      , "[body]" : bodyLines "text" (msgTextBody m) ++ bodyLines "html" (msgHtmlBody m)
      , "[attachments]" : map attachmentLine (msgAttachments m)
      ]
    addresses =
      [ name ++ " " ++ show k ++ " display=" ++ quote (addrDisplay a) ++ " spec=" ++ quote (addrSpec a)
      | name <- addressHeaders
      , (k, a) <- zip [0 :: Int ..] (messageAddresses m name)
      ]
    dateLines = case messageDate m of
      Nothing -> ["none"]
      Just (raw, Nothing) -> ["raw " ++ quote raw, "valid no"]
      Just (raw, Just d) ->
        [ "raw " ++ quote raw
        , "valid yes"
        , "utc " ++ formatUtc (dateEpoch d)
        , "offset " ++ formatOffset (dateOffset d)
        , "epoch " ++ show (dateEpoch d)
        ]
    structure = go (0 :: Int)
      where
        go d q = (d, q) : case partBody q of
          Multipart {mpChildren = cs} -> concatMap (go (d + 1)) cs
          MessageBody c -> go (d + 1) c
          Leaf {} -> []
    selectedRole p
      | fmap partIndex (msgTextBody m) == Just (partIndex p) = "text"
      | fmap partIndex (msgHtmlBody m) == Just (partIndex p) = "html"
      | otherwise = "attachment"
    structureLine (d, p) =
      concat (replicate d "  ") ++ show (partIndex p) ++ " " ++ partType p ++ "/" ++ partSubtype p
        ++ concatMap (' ' :) (attrs p)
    attrs p =
      [ "charset=" ++ c | Just c <- [partCharset p] ]
        ++ ["cte=" ++ partEncoding p]
        ++ [ "disposition=" ++ d | Just d <- [partDisposition p] ]
        ++ [ "filename=" ++ quote f | Just f <- [partFilename p] ]
        ++ case partBody p of
          Multipart b pre epi cs ->
            [ "boundary=" ++ quote b, "parts=" ++ show (length cs), "preamble=" ++ show pre
            , "epilogue=" ++ maybe "none" show epi ]
          MessageBody _ -> ["parts=1"]
          Leaf content _ ->
            [ "size=" ++ show (length' content), "adler32=" ++ adler32Hex content
            , "role=" ++ selectedRole p ]
    length' = B.length
    bodyLines label mp = case mp of
      Nothing -> [label ++ " none"]
      Just p ->
        let t = fromMaybe "" (leafText' p)
         in (label ++ " " ++ show (partIndex p) ++ " chars " ++ show (length t))
              : ["| " ++ esc l | l <- textLines t]
    attachmentLine p = case partBody p of
      Leaf content _ ->
        show (partIndex p) ++ " type=" ++ partType p ++ "/" ++ partSubtype p
          ++ " filename=" ++ maybe "-" quote (partFilename p)
          ++ " size=" ++ show (length' content) ++ " adler32=" ++ adler32Hex content
          ++ " file=" ++ attachmentPath no p
      _ -> ""
    leafText' p = case partBody p of Leaf _ t -> t; _ -> Nothing

-- | Split on LF, dropping a final empty piece.
textLines :: String -> [String]
textLines t = case pieces t of
  ps | not (null ps), null (last ps) -> init ps
     | otherwise -> ps
  where
    pieces s = case break (== '\n') s of
      (a, _ : r) -> a : pieces r
      (a, []) -> [a]
