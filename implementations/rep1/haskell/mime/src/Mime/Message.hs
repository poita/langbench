-- | Whole-message analysis: headers, addresses, date, body selection.
module Mime.Message
  ( Message (..)
  , parseMessage
  , messageParts
  , addressHeaders
  , messageAddresses
  , messageDate
  , isAttachmentPart
  ) where

import qualified Data.ByteString as B

import Mime.Address
import Mime.Bytes (normalizeNewlines)
import Mime.Date
import Mime.Header
import Mime.Part

-- | A parsed message.
data Message = Message
  { msgSize :: Int
  -- ^ length in bytes of the raw message
  , msgHeaders :: [Field]
  , msgRoot :: Part
  , msgTextBody :: Maybe Part
  , msgHtmlBody :: Maybe Part
  , msgAttachments :: [Part]
  }
  deriving (Show)

-- | Parse the bytes of one message.
parseMessage :: B.ByteString -> Message
parseMessage raw = Message
  { msgSize = B.length raw
  , msgHeaders = fst (parseHeaders norm)
  , msgRoot = root
  , msgTextBody = pick "plain"
  , msgHtmlBody = pick "html"
  , msgAttachments = [p | p <- leaves, not (selected p)]
  }
  where
    norm = normalizeNewlines raw
    root = fst (parsePart Nothing 0 norm)
    leaves = filter isLeaf (allParts root)
    candidates = filter (\p -> isLeaf p && partDisposition p /= Just "attachment") (walk root)
    -- pre-order, not descending into message/rfc822 containers
    walk p = p : case partBody p of
      Multipart {mpChildren = cs} -> concatMap walk cs
      _ -> []
    pick sub = case [p | p <- candidates, partType p == "text", partSubtype p == sub] of
      p : _ -> Just p
      [] -> Nothing
    textIdx = fmap partIndex (pick "plain")
    htmlIdx = fmap partIndex (pick "html")
    selected p = Just (partIndex p) == textIdx || Just (partIndex p) == htmlIdx

-- | All parts of the message in pre-order.
messageParts :: Message -> [Part]
messageParts = allParts . msgRoot

-- | Is the leaf an attachment (neither selected body)?
isAttachmentPart :: Message -> Part -> Bool
isAttachmentPart m p = partIndex p `elem` map partIndex (msgAttachments m)

-- | The address headers in output order.
addressHeaders :: [String]
addressHeaders = ["from", "sender", "reply-to", "to", "cc", "bcc"]

-- | The addresses of one header name, over all its fields in order.
messageAddresses :: Message -> String -> [Address]
messageAddresses m name = concatMap (parseAddressList . fieldRaw) (lookupFields name (msgHeaders m))

-- | The raw @Date@ value and its parse, if there is a Date header.
messageDate :: Message -> Maybe (String, Maybe ParsedDate)
messageDate m = case lookupField "date" (msgHeaders m) of
  Nothing -> Nothing
  Just f -> Just (fieldRaw f, parseDate (fieldRaw f))
