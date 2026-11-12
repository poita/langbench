-- | Recursive-descent parser for the pattern syntax.
--
-- > regex      := branch ( '|' branch )*
-- > branch     := piece*
-- > piece      := atom quantifier?
-- > atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
-- > quantifier := '*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' n ',' m '}'
module Regex.Parser
  ( ParseError (..)
  , parsePattern
  ) where

import Data.Char (isAlphaNum, isDigit, ord)
import Data.Word (Word8)

import qualified Regex.CharSet as CS
import Regex.Syntax

-- | A syntax error, with the 0-based offset in the pattern where it was found.
data ParseError = ParseError
  { errorOffset  :: !Int
  , errorMessage :: String
  } deriving (Eq, Show)

-- Parser state: remaining input, its offset, and the number of groups opened.
data St = St String !Int !Int

newtype P a = P { runP :: St -> Either ParseError (a, St) }

instance Functor P where
  fmap f (P p) = P $ \s -> case p s of
    Left e        -> Left e
    Right (a, s') -> Right (f a, s')

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
failAt msg = P $ \(St _ off _) -> Left (ParseError off msg)

peek :: P (Maybe Char)
peek = P $ \s@(St inp _ _) -> Right (case inp of { [] -> Nothing; (c:_) -> Just c }, s)

peek2 :: P (Maybe Char)
peek2 = P $ \s@(St inp _ _) -> Right (case inp of { (_:c:_) -> Just c; _ -> Nothing }, s)

advance :: P ()
advance = P $ \(St inp off g) -> Right ((), St (drop 1 inp) (off + 1) g)

nextGroup :: P Int
nextGroup = P $ \(St inp off g) -> Right (g + 1, St inp off (g + 1))

-- | Parse a whole pattern.  Characters above U+00FF are rejected.
parsePattern :: String -> Either ParseError Node
parsePattern src = case runP top (St src 0 0) of
  Left e       -> Left e
  Right (n, _) -> Right n
  where
    top = do
      n <- regex
      c <- peek
      case c of
        Nothing -> pure n
        Just ')' -> failAt "unmatched ')'"
        Just _   -> failAt "unexpected character"

regex :: P Node
regex = do
  b <- branch
  rest <- more
  pure (case rest of { [] -> b; _ -> Alt (b : rest) })
  where
    more = do
      c <- peek
      case c of
        Just '|' -> advance >> ((:) <$> branch <*> more)
        _        -> pure []

branch :: P Node
branch = Seq <$> go
  where
    go = do
      c <- peek
      case c of
        Nothing  -> pure []
        Just '|' -> pure []
        Just ')' -> pure []
        _        -> (:) <$> piece <*> go

piece :: P Node
piece = do
  a <- atom
  q <- peek
  case q of
    Just '*' -> advance >> quant a 0 Nothing
    Just '+' -> advance >> quant a 1 Nothing
    Just '?' -> advance >> quant a 0 (Just 1)
    Just '{' -> do
      advance
      lo <- number
      c <- peek
      case c of
        Just '}' -> advance >> quant a lo (Just lo)
        Just ',' -> do
          advance
          c' <- peek
          case c' of
            Just '}' -> advance >> quant a lo Nothing
            _        -> do
              hi <- number
              expect '}'
              if hi < lo then failAt "bad repetition range" else quant a lo (Just hi)
        _ -> failAt "malformed counted quantifier"
    _ -> pure a
  where
    quant a lo hi = case a of
      Bol -> failAt "quantifier after anchor"
      Eol -> failAt "quantifier after anchor"
      _   -> pure (Repeat lo hi a)

number :: P Int
number = do
  ds <- digitsP
  case ds of
    [] -> failAt "expected a number"
    _  -> pure (read ds)
  where
    digitsP = do
      c <- peek
      case c of
        Just d | isDigit d -> advance >> (d :) <$> digitsP
        _                  -> pure []

expect :: Char -> P ()
expect ch = do
  c <- peek
  if c == Just ch then advance else failAt ("expected '" ++ [ch] ++ "'")

atom :: P Node
atom = do
  mc <- peek
  case mc of
    Nothing -> failAt "unexpected end of pattern"
    Just c -> case c of
      '.' -> advance >> pure AnyChar
      '^' -> advance >> pure Bol
      '$' -> advance >> pure Eol
      '(' -> do
        advance
        g <- nextGroup
        r <- regex
        expect ')'
        pure (Group g r)
      '[' -> advance >> charClass
      '\\' -> advance >> escape
      _ | c `elem` "*+?{" -> failAt "nothing to repeat"
        | c `elem` "]})"  -> failAt ("unexpected '" ++ [c] ++ "'")
        | otherwise       -> Lit <$> byte c

byte :: Char -> P Word8
byte c
  | ord c < 256 = advance >> pure (fromIntegral (ord c))
  | otherwise   = failAt "character outside the supported range"

-- | After a backslash, outside a class.
escape :: P Node
escape = do
  mc <- peek
  case mc of
    Nothing -> failAt "dangling backslash"
    Just c -> case setEscape c of
      Just s -> advance >> pure (Set s)
      Nothing
        | isAlphaNum c -> failAt ("unknown escape '\\" ++ [c] ++ "'")
        | otherwise    -> Lit <$> byte c

setEscape :: Char -> Maybe CS.CharSet
setEscape c = case c of
  'd' -> Just CS.digits
  'D' -> Just (CS.complement CS.digits)
  'w' -> Just CS.wordChars
  'W' -> Just (CS.complement CS.wordChars)
  's' -> Just CS.spaceChars
  'S' -> Just (CS.complement CS.spaceChars)
  _   -> Nothing

-- | After the opening '['.
charClass :: P Node
charClass = do
  c <- peek
  neg <- case c of
    Just '^' -> advance >> pure True
    _        -> pure False
  items <- some1
  let s = CS.unions items
  pure (Set (if neg then CS.complement s else s))
  where
    some1 = do
      first <- item
      rest <- more
      pure (first : rest)
    more = do
      c <- peek
      case c of
        Just ']' -> advance >> pure []
        Nothing  -> failAt "unterminated character class"
        _        -> (:) <$> item <*> more

    item = do
      c <- peek
      case c of
        Just ']' -> failAt "empty character class"
        Just '\\' -> do
          c2 <- peek2
          case c2 >>= setEscape of
            Just s -> advance >> advance >> pure s
            Nothing -> rangeFrom
        _ -> rangeFrom

    rangeFrom = do
      lo <- single
      d <- peek
      e <- peek2
      case (d, e) of
        (Just '-', Just x) | x /= ']' -> do
          advance
          hi <- single
          if hi < lo then failAt "reversed range in class" else pure (CS.range lo hi)
        _ -> pure (CS.singleton lo)

    single = do
      c <- peek
      case c of
        Nothing -> failAt "unterminated character class"
        Just '\\' -> do
          advance
          c2 <- peek
          case c2 of
            Nothing -> failAt "dangling backslash"
            Just x
              | isAlphaNum x -> failAt ("unknown escape '\\" ++ [x] ++ "' in class")
              | otherwise    -> byte x
        Just x -> byte x
