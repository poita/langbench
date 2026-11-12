{-# LANGUAGE OverloadedStrings #-}

-- | Splitting a template source into text and tags, and tokenizing the
-- content of tags. Whitespace control (@{%-@, @-%}@ and friends) is applied
-- here, so the result contains the final text.
module Sitegen.Template.Lexer
  ( Token (..)
  , Item (..)
  , lexTemplate
  , isTemplateSpace
  ) where

import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import qualified Data.Text as T

-- | A token inside a @{{ }}@ or @{% %}@ tag.
data Token
  = TName !Text
  | TInt !Integer
  | TFloat !Double
  | TString !Text
  | TOp !Text
  deriving (Eq, Show)

-- | A piece of the template: literal text or a tag with its tokens.
data Item
  = IText !Text
  | IPrint [Token]
  | IStmt [Token]
  deriving (Eq, Show)

-- A tag before whitespace control is applied: left trim, right trim, and the
-- item (absent for comments).
data Raw = RText Text | RTag Bool Bool (Maybe Item)

-- | The whitespace of the template language (not Unicode whitespace).
isTemplateSpace :: Char -> Bool
isTemplateSpace c = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'

-- | Lex a template. 'Nothing' means a syntax error.
lexTemplate :: Text -> Maybe [Item]
lexTemplate src = trim <$> raws [] src
  where
    raws acc t = case findOpener t of
      Nothing -> Just (reverse (if T.null t then acc else RText t : acc))
      Just (pre, kind, rest) -> do
        (tag, rest') <- lexTag kind rest
        raws (tag : [RText pre | not (T.null pre)] ++ acc) rest'

findOpener :: Text -> Maybe (Text, Char, Text)
findOpener = go []
  where
    go acc s =
      let (a, b) = T.break (== '{') s
       in if T.null b
            then Nothing
            else case T.uncons (T.drop 1 b) of
              Just (c, r) | c == '{' || c == '%' || c == '#' -> Just (T.concat (reverse (a : acc)), c, r)
              _ -> go ("{" : a : acc) (T.drop 1 b)

lexTag :: Char -> Text -> Maybe (Raw, Text)
lexTag kind rest0 = do
  let (l, rest) = case T.uncons rest0 of
        Just ('-', r) -> (True, r)
        _ -> (False, rest0)
  case kind of
    '#' ->
      let (content, after) = T.breakOn "#}" rest
       in if T.null after
            then Nothing
            else Just (RTag l (T.isSuffixOf "-" content) Nothing, T.drop 2 after)
    _ -> do
      let isPrint = kind == '{'
      (toks, r, rest') <- tokenize isPrint rest
      Just (RTag l r (Just (if isPrint then IPrint toks else IStmt toks)), rest')

-- | Apply whitespace control and drop comments.
trim :: [Raw] -> [Item]
trim = go False
  where
    go _ [] = []
    go lstripNext (RText t : rest) =
      let t1 = if lstripNext then T.dropWhile isTemplateSpace t else t
          t2 = case rest of
            RTag True _ _ : _ -> T.dropWhileEnd isTemplateSpace t1
            _ -> t1
       in [IText t2 | not (T.null t2)] ++ go False rest
    go _ (RTag _ r item : rest) = maybe id (:) item (go r rest)

tokenize :: Bool -> Text -> Maybe ([Token], Bool, Text)
tokenize isPrint = go []
  where
    closer = if isPrint then "}}" else "%}"
    go acc s0 =
      let s = T.dropWhile isTemplateSpace s0
       in if T.null s
            then Nothing
            else
              if T.isPrefixOf (T.cons '-' closer) s
                then Just (reverse acc, True, T.drop 3 s)
                else
                  if T.isPrefixOf closer s
                    then Just (reverse acc, False, T.drop 2 s)
                    else do
                      (tok, rest) <- lexToken s
                      go (tok : acc) rest

lexToken :: Text -> Maybe (Token, Text)
lexToken s = case T.uncons s of
  Nothing -> Nothing
  Just (c, rest)
    | isNameStart c ->
        let (n, r) = T.span isNameChar s in Just (TName n, r)
    | isDigit c ->
        let (ds, r) = T.span isDigit s
         in case T.uncons r of
              Just ('.', r') | Just (d, _) <- T.uncons r', isDigit d ->
                let (fs, r'') = T.span isDigit r'
                 in Just (TFloat (read (T.unpack ds ++ "." ++ T.unpack fs)), r'')
              _ -> Just (TInt (read (T.unpack ds)), r)
    | c == '"' || c == '\'' -> lexString c rest
    | otherwise -> case filter (`T.isPrefixOf` s) twoChar of
        (op : _) -> Just (TOp op, T.drop 2 s)
        [] | c `elem` ("~+-*/%<>()[],|.=" :: String) -> Just (TOp (T.singleton c), rest)
           | otherwise -> Nothing
  where
    isNameStart ch = isAsciiLower ch || isAsciiUpper ch || ch == '_'
    isNameChar ch = isNameStart ch || (isAlphaNum ch && ch < '\x80')
    twoChar = ["**", "//", "==", "!=", "<=", ">="]

lexString :: Char -> Text -> Maybe (Token, Text)
lexString q = go []
  where
    go acc t = case T.uncons t of
      Nothing -> Nothing
      Just (c, r)
        | c == q -> Just (TString (T.pack (reverse acc)), r)
        | c == '\\' -> case T.uncons r of
            Just (e, r') -> do
              ch <- escape e
              go (ch : acc) r'
            Nothing -> Nothing
        | otherwise -> go (c : acc) r
    escape e = case e of
      '\\' -> Just '\\'
      '"' -> Just '"'
      '\'' -> Just '\''
      'n' -> Just '\n'
      't' -> Just '\t'
      _ -> Nothing
