-- | A small Jinja2-style template engine.
--
-- The supported language is a subset of Jinja2: variables and expressions,
-- the thirteen built-in filters, @if@ / @for@ / @set@, macros, @include@,
-- template inheritance (@extends@, @block@, @super()@), comments and
-- whitespace control.  Undefined variables are errors (as with Jinja2's
-- @StrictUndefined@), and nothing is auto-escaped.
--
-- > import qualified Data.Text as T
-- > import Template
-- >
-- > render [("name", VStr (T.pack "World"))]
-- >        [(T.pack "main", T.pack "Hello {{ name }}!")]
-- >        (T.pack "main")
-- > -- Right "Hello World!"
module Template
  ( -- * Rendering
    render
  , renderIO
    -- * Parsing
  , Template.Syntax.Template
  , parseTemplate
    -- * Values
  , Value (..)
  , Dict
  , dictFromList
  , dictToList
  , parseJson
    -- * Errors
  , ErrorKind (..)
  , errorKindName
    -- * Documents (the command-line input format)
  , Document (..)
  , parseDocument
  , renderDocument
  ) where

import Data.Text (Text)
import System.IO.Unsafe (unsafePerformIO)

import Template.Document
import Template.Error
import Template.Eval
import Template.Json
import Template.Parser
import qualified Template.Syntax
import Template.Value

-- | @render context templates name@ renders the template called @name@.
--
-- @context@ gives the initial variables; @templates@ are the named template
-- sources available to the rendered one through @include@ and @extends@.
-- Rendering is all-or-nothing: the first error aborts it.
render :: [(Text, Value)] -> [(Text, Text)] -> Text -> Either ErrorKind Text
render context templates name = unsafePerformIO (renderIO context templates name)
{-# NOINLINE render #-}
