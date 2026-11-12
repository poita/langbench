-- | Error codes and the @error.txt@ line format.
module Typeset.Error
  ( ErrFile (..)
  , ErrorCode (..)
  , Error (..)
  , codeName
  , renderError
  ) where

-- | The file an error is reported against.
data ErrFile = SettingsFile | DocumentFile | NoFile
  deriving (Eq, Show)

-- | Every error code of the specification.
data ErrorCode
  = MissingDocument | BadSyntax | UnknownSetting | DuplicateSetting
  | BadLength | BadInteger | BadBoolean | BadEnum | UnknownFont
  | UnknownPatterns | BadValue | BadEscape | UnknownPlaceholder | StrayBrace
  | UnknownBlock | BlockNotAllowed | DuplicateToc | UnexpectedEnd | MissingEnd
  | BadAttribute | MissingAttribute | BadAttributeValue | CellCount
  | TextNotAllowed | UnknownMeta | DuplicateMeta | UnknownInline
  | UnclosedInline | NestedFootnote | FootnoteNotAllowed
  deriving (Eq, Show, Enum, Bounded)

-- | A located error: file, 1-based line, 1-based column (in scalar values).
data Error = Error
  { errFile :: ErrFile
  , errLine :: Int
  , errCol  :: Int
  , errCode :: ErrorCode
  } deriving (Eq, Show)

-- | The kebab-case name used in @error.txt@.
codeName :: ErrorCode -> String
codeName c = case c of
  MissingDocument -> "missing-document"
  BadSyntax -> "bad-syntax"
  UnknownSetting -> "unknown-setting"
  DuplicateSetting -> "duplicate-setting"
  BadLength -> "bad-length"
  BadInteger -> "bad-integer"
  BadBoolean -> "bad-boolean"
  BadEnum -> "bad-enum"
  UnknownFont -> "unknown-font"
  UnknownPatterns -> "unknown-patterns"
  BadValue -> "bad-value"
  BadEscape -> "bad-escape"
  UnknownPlaceholder -> "unknown-placeholder"
  StrayBrace -> "stray-brace"
  UnknownBlock -> "unknown-block"
  BlockNotAllowed -> "block-not-allowed"
  DuplicateToc -> "duplicate-toc"
  UnexpectedEnd -> "unexpected-end"
  MissingEnd -> "missing-end"
  BadAttribute -> "bad-attribute"
  MissingAttribute -> "missing-attribute"
  BadAttributeValue -> "bad-attribute-value"
  CellCount -> "cell-count"
  TextNotAllowed -> "text-not-allowed"
  UnknownMeta -> "unknown-meta"
  DuplicateMeta -> "duplicate-meta"
  UnknownInline -> "unknown-inline"
  UnclosedInline -> "unclosed-inline"
  NestedFootnote -> "nested-footnote"
  FootnoteNotAllowed -> "footnote-not-allowed"

-- | The single line of @error.txt@ (without the trailing newline).
renderError :: Error -> String
renderError (Error f l c code) =
  file ++ ":" ++ show l ++ ":" ++ show c ++ ": " ++ codeName code
  where
    file = case f of
      SettingsFile -> "settings.cfg"
      DocumentFile -> "document.cdx"
      NoFile -> "-"
