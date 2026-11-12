-- | A Jinja-style template engine.
--
-- Templates support @{{ expr }}@ printing, @if@\/@for@\/@set@\/@macro@
-- statements, @include@, template inheritance with @extends@, @block@ and
-- @super()@, whitespace control, and thirteen built-in filters.
--
-- > let tpls = mkTemplates [("hello", "Hello {{ name|upper }}!")]
-- > renderTemplate tpls "hello" [("name", VString "world")]
-- > -- Right "Hello WORLD!"
module Sitegen.Template
  ( -- * Template sets
    Templates
  , mkTemplates
  , templateNames
    -- * Rendering
  , renderTemplate
  , ErrorKind (..)
  , errorKindName
    -- * Values
  , Value (..)
  , mkDict
  , mkList
  , displayValue
  ) where

import Sitegen.Template.Eval
import Sitegen.Template.Syntax (ErrorKind (..), errorKindName)
import Sitegen.Template.Value
