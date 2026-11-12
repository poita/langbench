{-# LANGUAGE OverloadedStrings #-}
-- | Lexing: splits a template body into text and tags, applies whitespace
-- control, and tokenizes the content of @{{ }}@ and @{% %}@ tags.
module Template.Lexer
  ( Tok (..)
  , Item (..)
  , lexTemplate
  , lexExpression
  , isWs
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T

import Template.Error

-- | A token inside a tag.
data Tok
  = TName !Text
  | TInt !Integer
  | TFloat !Double
  | TStr !Text
  | TOp !Text
  deriving (Eq, Show)

-- | A piece of a template body.  Comments produce no item.
data Item
  = ItemText !Text
  | ItemPrint [Tok]   -- ^ @{{ ... }}@
  | ItemTag [Tok]     -- ^ @{% ... %}@
  deriving (Eq, Show)

-- | The whitespace characters recognised by the language.
isWs :: Char -> Bool
isWs c = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'

-- | Split a template body into items, applying @-@ whitespace control.
lexTemplate :: Text -> Either ErrorKind [Item]
lexTemplate = go False []
  where
    go :: Bool -> [Item] -> Text -> Either ErrorKind [Item]
    go stripNext acc src = case scanOpen src [] of
      Left pieces ->
        let txt = leftStrip stripNext (T.concat (reverse pieces))
        in Right (reverse (addText txt acc))
      Right (pieces, kind, afterOpen) -> do
        let (dashL, body) = case T.uncons afterOpen of
              Just ('-', r) -> (True, r)
              _ -> (False, afterOpen)
            txt0 = leftStrip stripNext (T.concat (reverse pieces))
            txt = if dashL then T.dropWhileEnd isWs txt0 else txt0
            acc1 = addText txt acc
        case kind of
          '#' -> do
            let (content, after) = T.breakOn "#}" body
            if T.null after
              then Left ErrSyntax
              else go (not (T.null content) && T.last content == '-')
                      acc1 (T.drop 2 after)
          '{' -> do
            (toks, dashR, rest) <- lexTag "}}" body
            go dashR (ItemPrint toks : acc1) rest
          _ -> do
            (toks, dashR, rest) <- lexTag "%}" body
            go dashR (ItemTag toks : acc1) rest

    leftStrip s t = if s then T.dropWhile isWs t else t
    addText t acc = if T.null t then acc else ItemText t : acc

-- Find the next tag opener.  Returns the text pieces (reversed) before it,
-- the opener's second character and the text after the opener.
scanOpen :: Text -> [Text] -> Either [Text] ([Text], Char, Text)
scanOpen s ps =
  let (pre, r) = T.break (== '{') s
  in case T.uncons r of
       Nothing -> Left (pre : ps)
       Just (_, r1) -> case T.uncons r1 of
         Just (c, r2) | c == '{' || c == '%' || c == '#' -> Right (pre : ps, c, r2)
         _ -> scanOpen r1 ("{" : pre : ps)

-- | Tokenize the content of a tag up to its closer.  Returns the tokens,
-- whether the closer had a @-@ (strip following whitespace) and the rest.
lexTag :: Text -> Text -> Either ErrorKind ([Tok], Bool, Text)
lexTag closer = loop []
  where
    dashCloser = T.cons '-' closer
    loop acc s0 =
      let s = T.dropWhile isWs s0
      in case T.uncons s of
        Nothing -> Left ErrSyntax
        Just (c, r)
          | Just rest <- T.stripPrefix dashCloser s -> Right (reverse acc, True, rest)
          | Just rest <- T.stripPrefix closer s -> Right (reverse acc, False, rest)
          | isNameStart c ->
              let (nm, rest) = T.span isNameChar s
              in loop (TName nm : acc) rest
          | isDigit c -> lexNumber acc s
          | c == '"' || c == '\'' -> lexString c r >>= \(str, rest) -> loop (TStr str : acc) rest
          | otherwise -> case operator s of
              Just (op, rest) -> loop (TOp op : acc) rest
              Nothing -> Left ErrSyntax
    lexNumber acc s =
      let (ds, r) = T.span isDigit s
      in case T.uncons r of
           Just ('.', r1) | Just (d, _) <- T.uncons r1, isDigit d ->
             let (fs, rest) = T.span isDigit r1
                 num = read (T.unpack (ds <> fs)) :: Integer
                 val = fromRational (num % (10 ^ T.length fs)) :: Double
             in loop (TFloat val : acc) rest
           _ -> loop (TInt (read (T.unpack ds)) : acc) r

-- | Tokenize a standalone expression (used by tests and tooling).
lexExpression :: Text -> Either ErrorKind [Tok]
lexExpression t = case lexTag "}}" (t <> " }}") of
  Right (toks, _, rest) | T.null rest -> Right toks
  Right _ -> Left ErrSyntax
  Left e -> Left e

isNameStart, isNameChar :: Char -> Bool
isNameStart c = isAsciiLower c || isAsciiUpper c || c == '_'
isNameChar c = isNameStart c || isDigit c

operator :: Text -> Maybe (Text, Text)
operator s = case [(op, r) | op <- twoChar, Just r <- [T.stripPrefix op s]] of
  (x : _) -> Just x
  [] -> case T.uncons s of
    Just (c, r) | c `elem` ("~+-*/%<>()[],|.=" :: String) -> Just (T.singleton c, r)
    _ -> Nothing
  where
    twoChar = ["**", "//", "==", "!=", "<=", ">="]

-- Lex a string literal whose opening quote has been consumed.
lexString :: Char -> Text -> Either ErrorKind (Text, Text)
lexString q = go []
  where
    go acc s =
      let (chunk, r) = T.break (\c -> c == q || c == '\\') s
      in case T.uncons r of
        Nothing -> Left ErrSyntax
        Just (c, r1)
          | c == q -> Right (T.concat (reverse (chunk : acc)), r1)
          | otherwise -> case T.uncons r1 of
              Just (e, r2) -> case escape e of
                Just ch -> go (T.singleton ch : chunk : acc) r2
                Nothing -> Left ErrSyntax
              Nothing -> Left ErrSyntax
    escape e = case e of
      '\\' -> Just '\\'
      '"' -> Just '"'
      '\'' -> Just '\''
      'n' -> Just '\n'
      't' -> Just '\t'
      _ -> Nothing
