-- | A tiny non-validating XML parser: just enough for SVG documents made of
-- elements and attributes (SPEC §3).
--
-- Processing instructions, comments, @DOCTYPE@ declarations and CDATA
-- sections are skipped; character data is ignored. Namespace prefixes are
-- stripped from element and attribute names.
module Graphics.SVG.Raster.Xml
  ( Element (..)
  , parseXml
  , attr
  , decodeEntities
  ) where

import Data.Char (chr, isAlphaNum, isHexDigit, isSpace, digitToInt, isDigit)
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

-- | An XML element.
data Element = Element
  { elName :: String
  -- ^ Tag name with any namespace prefix removed.
  , elAttrs :: Map String String
  -- ^ Attributes (prefix removed, entities resolved); the last duplicate wins.
  , elChildren :: [Element]
  -- ^ Child elements in document order.
  }
  deriving (Eq, Show)

-- | Attribute lookup.
attr :: String -> Element -> Maybe String
attr k = Map.lookup k . elAttrs

-- | Parse a document and return its root element (the first start tag).
-- Returns 'Nothing' if the text contains no element. Malformed input is
-- handled leniently: unterminated constructs end at the end of the input.
parseXml :: String -> Maybe Element
parseXml = findRoot
  where
    findRoot s = case dropWhile (/= '<') s of
      [] -> Nothing
      rest -> case skipSpecial rest of
        Just rest' -> findRoot rest'
        Nothing -> case rest of
          '<' : '/' : _ -> findRoot (drop 1 rest)
          _ -> Just (fst (parseElement (drop 1 rest)))

-- | If the input starts with a non-element construct, skip it.
skipSpecial :: String -> Maybe String
skipSpecial s
  | "<?" `isPrefixOf` s = Just (afterStr "?>" (drop 2 s))
  | "<!--" `isPrefixOf` s = Just (afterStr "-->" (drop 4 s))
  | "<![CDATA[" `isPrefixOf` s = Just (afterStr "]]>" (drop 9 s))
  | "<!" `isPrefixOf` s = Just (skipDecl (0 :: Int) (drop 2 s))
  | otherwise = Nothing

afterStr :: String -> String -> String
afterStr _ [] = []
afterStr pat s@(_ : rest)
  | pat `isPrefixOf` s = drop (length pat) s
  | otherwise = afterStr pat rest

-- | Skip a @<!...>@ declaration, honouring an internal @[...]@ subset and
-- quoted strings.
skipDecl :: Int -> String -> String
skipDecl _ [] = []
skipDecl depth (c : cs)
  | c == '>' && depth == 0 = cs
  | c == '[' = skipDecl (depth + 1) cs
  | c == ']' = skipDecl (max 0 (depth - 1)) cs
  | c == '"' || c == '\'' = skipDecl depth (drop 1 (dropWhile (/= c) cs))
  | "<!--" `isPrefixOf` (c : cs) = skipDecl depth (afterStr "-->" (drop 3 cs))
  | otherwise = skipDecl depth cs

-- | Parse an element whose @<@ has just been consumed.
parseElement :: String -> (Element, String)
parseElement s0 =
  let (rawName, s1) = span isNameChar s0
      (attrs, s2, selfClosing) = parseAttrs s1 []
      name = stripPrefix rawName
      attrMap = Map.fromList [(stripPrefix k, decodeEntities v) | (k, v) <- attrs]
   in if selfClosing
        then (Element name attrMap [], s2)
        else
          let (kids, s3) = parseContent s2
           in (Element name attrMap kids, s3)

-- | Parse the content of an element up to and including its end tag.
parseContent :: String -> ([Element], String)
parseContent s = case dropWhile (/= '<') s of
  [] -> ([], [])
  rest
    | "</" `isPrefixOf` rest -> ([], drop 1 (dropWhile (/= '>') rest))
    | Just rest' <- skipSpecial rest -> parseContent rest'
    | otherwise ->
        let (el, rest') = parseElement (drop 1 rest)
            (els, rest'') = parseContent rest'
         in (el : els, rest'')

isNameChar :: Char -> Bool
isNameChar c = isAlphaNum c || c `elem` ":_-." || c > '\x7f'

stripPrefix :: String -> String
stripPrefix n = case break (== ':') n of
  (_, ':' : rest) -> stripPrefix rest
  _ -> n

-- | Parse attributes up to the end of the start tag. The flag is 'True' for
-- a self-closing tag.
parseAttrs :: String -> [(String, String)] -> ([(String, String)], String, Bool)
parseAttrs s acc = case dropWhile isSpace s of
  [] -> (reverse acc, [], True)
  '/' : rest -> (reverse acc, drop 1 (dropWhile (/= '>') rest), True)
  '>' : rest -> (reverse acc, rest, False)
  s1 ->
    let (name, s2) = span isNameChar s1
     in if null name
          then parseAttrs (drop 1 s1) acc
          else case dropWhile isSpace s2 of
            '=' : s3 -> case dropWhile isSpace s3 of
              q : s4 | q == '"' || q == '\'' ->
                let (val, s5) = break (== q) s4
                 in parseAttrs (drop 1 s5) ((name, val) : acc)
              s4 -> parseAttrs s4 acc
            s3 -> parseAttrs s3 acc

-- | Resolve @&amp; &lt; &gt; &quot; &apos;@ and numeric character
-- references; other @&...;@ sequences are left as they are.
decodeEntities :: String -> String
decodeEntities [] = []
decodeEntities ('&' : rest) = case break (== ';') (take 12 rest) of
  (name, ';' : _)
    | Just c <- entity name -> c : decodeEntities (drop (length name + 1) rest)
  _ -> '&' : decodeEntities rest
decodeEntities (c : cs) = c : decodeEntities cs

entity :: String -> Maybe Char
entity "amp" = Just '&'
entity "lt" = Just '<'
entity "gt" = Just '>'
entity "quot" = Just '"'
entity "apos" = Just '\''
entity ('#' : 'x' : hs) | not (null hs), all isHexDigit hs = codePoint (foldl (\a d -> a * 16 + digitToInt d) 0 hs)
entity ('#' : ds) | not (null ds), all isDigit ds = codePoint (foldl (\a d -> a * 10 + digitToInt d) 0 ds)
entity _ = Nothing

codePoint :: Int -> Maybe Char
codePoint n
  | n >= 0 && n <= 0x10ffff = Just (chr n)
  | otherwise = Nothing
