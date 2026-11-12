{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : JsonSchema.Uri
-- Description : RFC 3986 reference parsing and resolution.
--
-- Only what JSON Schema needs: splitting a URI reference into its five
-- components, strict reference resolution (RFC 3986 section 5.2.2, including
-- @remove_dot_segments@), recomposition, and percent-decoding of fragments.
module JsonSchema.Uri
  ( Uri (..)
  , parseUri
  , renderUri
  , resolve
  , removeDotSegments
  , withoutFragment
  , splitFragment
  , percentDecode
  ) where

import Data.Char (digitToInt, isHexDigit)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import Data.Word (Word8)

-- | A URI reference split into its components.  @Nothing@ means "undefined",
-- which differs from "defined but empty" (@a#@ has fragment @Just ""@).
data Uri = Uri
  { uriScheme :: Maybe Text
  , uriAuthority :: Maybe Text
  , uriPath :: Text
  , uriQuery :: Maybe Text
  , uriFragment :: Maybe Text
  } deriving (Eq, Show)

-- | Split a URI reference (RFC 3986 appendix B).  Never fails.
parseUri :: Text -> Uri
parseUri s0 = Uri scheme authority path query fragment
  where
    (beforeFrag, fragPart) = T.break (== '#') s0
    fragment = if T.null fragPart then Nothing else Just (T.drop 1 fragPart)
    (beforeQuery, queryPart) = T.break (== '?') beforeFrag
    query = if T.null queryPart then Nothing else Just (T.drop 1 queryPart)
    (scheme, rest1) =
      let (sch, r) = T.break (\c -> c == ':' || c == '/') beforeQuery
       in case T.uncons r of
            Just (':', r') | not (T.null sch) -> (Just sch, r')
            _ -> (Nothing, beforeQuery)
    (authority, path) = case T.stripPrefix "//" rest1 of
      Just r -> let (a, p) = T.break (== '/') r in (Just a, p)
      Nothing -> (Nothing, rest1)

-- | Recompose a URI reference (RFC 3986 section 5.3).
renderUri :: Uri -> Text
renderUri (Uri sch auth p q f) =
  T.concat
    [ maybe "" (`T.snoc` ':') sch
    , maybe "" ("//" <>) auth
    , p
    , maybe "" ("?" <>) q
    , maybe "" ("#" <>) f
    ]

-- | @resolve base ref@: strict reference resolution (RFC 3986 section 5.2.2).
resolve :: Uri -> Uri -> Uri
resolve base r
  | Just _ <- uriScheme r = r {uriPath = removeDotSegments (uriPath r)}
  | Just _ <- uriAuthority r =
      r {uriScheme = uriScheme base, uriPath = removeDotSegments (uriPath r)}
  | T.null (uriPath r) =
      base
        { uriQuery = case uriQuery r of
            Nothing -> uriQuery base
            q -> q
        , uriFragment = uriFragment r
        }
  | "/" `T.isPrefixOf` uriPath r =
      base {uriPath = removeDotSegments (uriPath r), uriQuery = uriQuery r, uriFragment = uriFragment r}
  | otherwise =
      base {uriPath = removeDotSegments (merge (uriPath r)), uriQuery = uriQuery r, uriFragment = uriFragment r}
  where
    merge rp
      | Just _ <- uriAuthority base, T.null (uriPath base) = "/" <> rp
      | otherwise =
          let (dir, _) = T.breakOnEnd "/" (uriPath base) in dir <> rp

-- | RFC 3986 section 5.2.4.
removeDotSegments :: Text -> Text
removeDotSegments input = go (T.unpack input) []
  where
    -- output is a reversed list of segments (each including a leading '/' when present)
    go :: String -> [String] -> Text
    go [] out = T.pack (concat (reverse out))
    go s out
      | Just r <- pre "../" s = go r out
      | Just r <- pre "./" s = go r out
      | Just r <- pre "/./" s = go ('/' : r) out
      | s == "/." = go "/" out
      | Just r <- pre "/../" s = go ('/' : r) (pop out)
      | s == "/.." = go "/" (pop out)
      | s == "." || s == ".." = go [] out
      | otherwise =
          let (seg, rest) = segment s in go rest (seg : out)
    pop (_ : xs) = xs
    pop [] = []
    pre p s = if take (length p) s == p then Just (drop (length p) s) else Nothing
    segment s = case s of
      ('/' : r) -> let (a, b) = break (== '/') r in ('/' : a, b)
      _ -> break (== '/') s

-- | Drop the fragment, if any.
withoutFragment :: Uri -> Uri
withoutFragment u = u {uriFragment = Nothing}

-- | Split a reference into its document part (no fragment) and its
-- percent-decoded fragment (empty when absent).
splitFragment :: Uri -> (Text, Text)
splitFragment u = (renderUri (withoutFragment u), maybe "" percentDecode (uriFragment u))

-- | Percent-decode (as UTF-8).  Malformed escapes are kept literally.
percentDecode :: Text -> Text
percentDecode t
  | not (T.any (== '%') t) = t
  | otherwise = TE.decodeUtf8With TE.lenientDecode (B.pack (go (T.unpack t)))
  where
    go :: String -> [Word8]
    go ('%' : a : b : r) | isHexDigit a && isHexDigit b = fromIntegral (digitToInt a * 16 + digitToInt b) : go r
    go (c : r) = B.unpack (TE.encodeUtf8 (T.singleton c)) ++ go r
    go [] = []
