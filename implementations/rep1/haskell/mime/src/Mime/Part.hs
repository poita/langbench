-- | The MIME part tree.
module Mime.Part
  ( Part (..)
  , PartBody (..)
  , parsePart
  , isLeaf
  , allParts
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC

import Mime.Bytes (dropOneTrailingLF, normalizeNewlines)
import Mime.Charset (decode, encodeUtf8, normalizeCharset)
import Mime.Header
import Mime.Lexical
import Mime.Params
import Mime.Transfer (decodeBody)

-- | A node of the MIME tree.
data Part = Part
  { partIndex :: !Int
  -- ^ pre-order number; the whole message is part 0
  , partType :: String
  , partSubtype :: String
  , partCharset :: Maybe String
  -- ^ normalised charset name, for @text/*@ parts
  , partEncoding :: String
  , partDisposition :: Maybe String
  , partFilename :: Maybe String
  , partBody :: PartBody
  }
  deriving (Show)

-- | What a part holds.
data PartBody
  = Multipart
      { mpBoundary :: String
      , mpPreamble :: Int
      , mpEpilogue :: Maybe Int
      , mpChildren :: [Part]
      }
  | MessageBody Part
  | Leaf
      { leafContent :: B.ByteString
      , leafText :: Maybe String
      }
  deriving (Show)

-- | Is the part a leaf?
isLeaf :: Part -> Bool
isLeaf p = case partBody p of Leaf {} -> True; _ -> False

-- | All parts in pre-order.
allParts :: Part -> [Part]
allParts p = p : case partBody p of
  Multipart {mpChildren = cs} -> concatMap allParts cs
  MessageBody c -> allParts c
  Leaf {} -> []

-- | @parsePart parentType index bytes@ parses a part (bytes with LF line
-- endings) and numbers it and its descendants from @index@; also returns the
-- next free index.
parsePart :: Maybe (String, String) -> Int -> B.ByteString -> (Part, Int)
parsePart parent idx raw = (part, next)
  where
    (fields, body) = parseHeaders raw
    ctField = fmap (parseStructured . fieldRaw) (lookupField "content-type" fields)
    cdField = fmap (parseStructured . fieldRaw) (lookupField "content-disposition" fields)
    cteField = fmap (parseStructured . fieldRaw) (lookupField "content-transfer-encoding" fields)
    defaultType
      | parent == Just ("multipart", "digest") = ("message", "rfc822")
      | otherwise = ("text", "plain")
    (ty, sub) = case ctField >>= validType . lowerStr . stripBlanks . structValue of
      Just t -> t
      Nothing -> defaultType
    ctParam k = ctField >>= paramLookup k
    encoding = maybe "7bit" (lowerStr . stripBlanks . structValue) cteField
    disposition = fmap dispType cdField
    dispType s = case lowerStr (stripBlanks (structValue s)) of
      "" -> "inline"
      d -> d
    filename = case cdField >>= paramLookup "filename" of
      Just f -> Just f
      Nothing -> ctParam "name"
    charset
      | ty == "text" = Just (maybe "us-ascii" normalizeCharset (ctParam "charset"))
      | otherwise = Nothing
    boundary = case ctParam "boundary" of
      Just b | ty == "multipart", not (null b) -> Just b
      _ -> Nothing
    self = (ty, sub)
    mk b = Part idx ty sub charset encoding disposition filename b
    (part, next) = case boundary of
      Just b ->
        let (pre, epi, kids) = splitMultipart (encodeUtf8 b) body
            (cs, nx) = foldl' step ([], idx + 1) kids
            step (acc, i) k = let (c, i') = parsePart (Just self) i k in (c : acc, i')
         in (mk (Multipart b (B.length pre) (fmap B.length epi) (reverse cs)), nx)
      Nothing
        | (ty, sub) == ("message", "rfc822") ->
            let (c, nx) = parsePart (Just self) (idx + 1) (normalizeNewlines (decodeBody encoding body))
             in (mk (MessageBody c), nx)
        | otherwise ->
            let content = decodeBody encoding body
                text = if ty == "text" then Just (decode (maybe "" id charset) content) else Nothing
             in (mk (Leaf content text), idx + 1)

-- | A content type is usable when it is @token/token@.
validType :: String -> Maybe (String, String)
validType s = case break (== '/') s of
  (t, '/' : st) | tok t, tok st -> Just (t, st)
  _ -> Nothing
  where
    tok x = not (null x) && not (any (`elem` " \t()<>@,;:\\\"/[]?=") x)

-- | Split a multipart body into preamble, epilogue and child byte strings.
splitMultipart :: B.ByteString -> B.ByteString -> (B.ByteString, Maybe B.ByteString, [B.ByteString])
splitMultipart bb body = case delims of
  [] -> (body, Nothing, [])
  (start0, after0, close0) : more ->
    let pre = dropOneTrailingLF (B.take start0 body)
     in if close0
          then (pre, Just (B.drop after0 body), [])
          else let (epi, kids) = children after0 more in (pre, epi, kids)
  where
    prefix = BC.pack "--" <> bb
    -- (start of line, offset after terminator, is close delimiter)
    delims = scan 0
    n = B.length body
    scan o
      | o >= n = []
      | otherwise =
          let rest = B.drop o body
              (line, next) = case B.elemIndex 10 rest of
                Just i -> (B.take i rest, o + i + 1)
                Nothing -> (rest, n)
           in case delimiter line of
                Just c -> (o, next, c) : scan next
                Nothing -> scan next
    delimiter line
      | prefix `B.isPrefixOf` line =
          let r = B.drop (B.length prefix) line
              (isClose, r') = if BC.pack "--" `B.isPrefixOf` r then (True, B.drop 2 r) else (False, r)
           in if B.all (\w -> w == 32 || w == 9) r' then Just isClose else Nothing
      | otherwise = Nothing
    children from ds = case ds of
      [] -> (Nothing, [dropOneTrailingLF (B.drop from body)])
      (s, a, close) : rest ->
        let kid = dropOneTrailingLF (B.take (s - from) (B.drop from body))
         in if close
              then (Just (B.drop a body), [kid])
              else let (e, ks) = children a rest in (e, kid : ks)
