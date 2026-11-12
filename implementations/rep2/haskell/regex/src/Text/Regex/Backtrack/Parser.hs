-- |
-- Module      : Text.Regex.Backtrack.Parser
-- Description : Recursive-descent parser from pattern text to a syntax tree.
--
-- Grammar (see the README for the full description):
--
-- > regex      := branch ( '|' branch )*
-- > branch     := piece*
-- > piece      := atom quantifier?
-- > atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
-- > quantifier := '*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' n ',' m '}'
module Text.Regex.Backtrack.Parser
  ( ParseError (..)
  , parseRegex
  , maxRepeat
  ) where

import Data.Char (isAlphaNum, isDigit, isAscii, isPrint, ord)

import Text.Regex.Backtrack.CharSet (CharSet)
import qualified Text.Regex.Backtrack.CharSet as CS
import Text.Regex.Backtrack.Syntax

-- | A syntax error: the 0-based offset in the pattern and a description.
data ParseError = ParseError
  { parseErrorOffset  :: !Int
  , parseErrorMessage :: String
  } deriving (Eq, Show)

-- | Largest value accepted in a counted quantifier @{n,m}@.
maxRepeat :: Int
maxRepeat = 100

-- Parser state: absolute offset, remaining input, groups opened so far.
data St = St !Int String !Int

newtype P a = P { runP :: St -> Either ParseError (a, St) }

instance Functor P where
  fmap f (P p) = P $ \s -> case p s of
    Left e         -> Left e
    Right (a, s')  -> Right (f a, s')

instance Applicative P where
  pure a = P $ \s -> Right (a, s)
  P pf <*> P pa = P $ \s -> case pf s of
    Left e        -> Left e
    Right (f, s') -> case pa s' of
      Left e         -> Left e
      Right (a, s'') -> Right (f a, s'')

instance Monad P where
  P p >>= f = P $ \s -> case p s of
    Left e        -> Left e
    Right (a, s') -> runP (f a) s'

failAt :: String -> P a
failAt msg = P $ \(St off _ _) -> Left (ParseError off msg)

peek :: P (Maybe Char)
peek = P $ \s@(St _ r _) -> Right (case r of { [] -> Nothing; (c : _) -> Just c }, s)

peek2 :: P (Maybe Char)
peek2 = P $ \s@(St _ r _) -> Right (case r of { (_ : c : _) -> Just c; _ -> Nothing }, s)

advance :: P ()
advance = P $ \(St off r g) -> Right ((), St (off + 1) (drop 1 r) g)

nextGroup :: P Int
nextGroup = P $ \(St off r g) -> Right (g + 1, St off r (g + 1))

groupCount :: P Int
groupCount = P $ \s@(St _ _ g) -> Right (g, s)

-- | Parse a pattern. On success returns the tree and number of groups.
parseRegex :: String -> Either ParseError Pattern
parseRegex src =
  case runP top (St 0 src 0) of
    Left e              -> Left e
    Right (r, _)        -> Right r
  where
    top = do
      n <- regex
      mc <- peek
      case mc of
        Nothing -> do g <- groupCount; pure (Pattern n g)
        Just ')' -> failAt "unmatched ')'"
        Just c -> failAt ("unexpected " ++ show c)

regex :: P Node
regex = do
  b <- branch
  rest <- more
  pure (case rest of { [] -> b; _ -> Alt (b : rest) })
  where
    more = do
      mc <- peek
      case mc of
        Just '|' -> advance >> ((:) <$> branch <*> more)
        _        -> pure []

branch :: P Node
branch = Seq <$> go
  where
    go = do
      mc <- peek
      case mc of
        Nothing  -> pure []
        Just '|' -> pure []
        Just ')' -> pure []
        _        -> (:) <$> piece <*> go

piece :: P Node
piece = do
  (a, quantifiable) <- atom
  mc <- peek
  case mc of
    Just q | quantifiable, q `elem` "*+?{" -> quantifier q a
    _ -> pure a

quantifier :: Char -> Node -> P Node
quantifier q a = case q of
  '*' -> advance >> pure (Repeat 0 Nothing a)
  '+' -> advance >> pure (Repeat 1 Nothing a)
  '?' -> advance >> pure (Repeat 0 (Just 1) a)
  _   -> do
    advance
    n <- number
    mc <- peek
    case mc of
      Just '}' -> advance >> pure (Repeat n (Just n) a)
      Just ',' -> do
        advance
        mc' <- peek
        case mc' of
          Just '}' -> advance >> pure (Repeat n Nothing a)
          _ -> do
            m <- number
            expect '}'
            if m < n then failAt "quantifier maximum is below minimum"
                     else pure (Repeat n (Just m) a)
      _ -> failAt "malformed counted quantifier"

number :: P Int
number = do
  ds <- digits
  case ds of
    [] -> failAt "expected a number"
    _ | length ds > 3 || read ds > maxRepeat -> failAt ("repeat count exceeds " ++ show maxRepeat)
      | otherwise -> pure (read ds)
  where
    digits = do
      mc <- peek
      case mc of
        Just c | isDigit c -> advance >> (c :) <$> digits
        _ -> pure []

expect :: Char -> P ()
expect c = do
  mc <- peek
  if mc == Just c then advance else failAt ("expected " ++ show c)

-- | Parse one atom; the flag says whether a quantifier may follow.
atom :: P (Node, Bool)
atom = do
  mc <- peek
  case mc of
    Nothing -> failAt "unexpected end of pattern"
    Just c -> case c of
      '.'  -> advance >> pure (AnyChar, True)
      '^'  -> advance >> pure (StartAnchor, False)
      '$'  -> advance >> pure (EndAnchor, False)
      '('  -> do
        advance
        g <- nextGroup
        r <- regex
        expect ')'
        pure (Group g r, True)
      '['  -> advance >> (\s -> (Class s, True)) <$> classBody
      '\\' -> advance >> (\n -> (n, True)) <$> escape
      _ | c `elem` "*+?{" -> failAt "nothing to repeat"
        | c `elem` "]}"   -> failAt ("unescaped " ++ show c)
        | otherwise -> advance >> pure (Literal c, True)

-- Escape outside a class (backslash already consumed).
escape :: P Node
escape = do
  mc <- peek
  case mc of
    Nothing -> failAt "trailing backslash"
    Just c -> do
      advance
      case setEscape c of
        Just s -> pure (Class s)
        Nothing
          | isAlphaNum c -> failAt ("unknown escape \\" ++ [c])
          | otherwise    -> pure (Literal c)

setEscape :: Char -> Maybe CharSet
setEscape c = case c of
  'd' -> Just digitSet
  'D' -> Just (CS.complement digitSet)
  'w' -> Just wordSet
  'W' -> Just (CS.complement wordSet)
  's' -> Just spaceSet
  'S' -> Just (CS.complement spaceSet)
  _   -> Nothing

digitSet, wordSet, spaceSet :: CharSet
digitSet = CS.range '0' '9'
wordSet  = CS.unions [CS.range 'A' 'Z', CS.range 'a' 'z', digitSet, CS.singleton '_']
spaceSet = CS.fromList " \t\n\r\f\v"

-- Class body after '[' up to and including ']'.
classBody :: P CharSet
classBody = do
  mc <- peek
  neg <- case mc of
    Just '^' -> advance >> pure True
    _        -> pure False
  items <- classItems True
  pure (if neg then CS.complement items else items)

classItems :: Bool -> P CharSet
classItems isFirst = do
  mc <- peek
  case mc of
    Nothing -> failAt "unterminated character class"
    Just ']'
      | isFirst   -> failAt "empty character class"
      | otherwise -> advance >> pure CS.empty
    Just '\\' -> do
      mc2 <- peek2
      case mc2 >>= setEscape of
        Just s -> advance >> advance >> (CS.union s <$> classItems False)
        Nothing -> single >>= rangeOrChar
    _ -> single >>= rangeOrChar
  where
    rangeOrChar lo = do
      m1 <- peek
      m2 <- peek2
      case (m1, m2) of
        (Just '-', Just c) | c /= ']' -> do
          advance
          hi <- single
          if hi < lo then failAt "range out of order"
                     else CS.union (CS.range lo hi) <$> classItems False
        _ -> CS.union (CS.singleton lo) <$> classItems False

-- A single class character: anything but ']' and '\', or '\' + non-alphanumeric.
single :: P Char
single = do
  mc <- peek
  case mc of
    Nothing -> failAt "unterminated character class"
    Just '\\' -> do
      advance
      mc2 <- peek
      case mc2 of
        Nothing -> failAt "trailing backslash"
        Just c
          | isAlphaNum c -> failAt ("unexpected escape \\" ++ [c] ++ " in class")
          | otherwise -> advance >> checked c
    Just c -> advance >> checked c
  where
    checked c
      | isAscii c && isPrint c || ord c < 256 = pure c
      | otherwise = failAt "character outside the supported 8-bit range"
