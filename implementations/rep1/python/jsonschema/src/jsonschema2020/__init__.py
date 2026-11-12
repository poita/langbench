"""jsonschema2020 -- a JSON Schema draft 2020-12 validator in pure Python.

Quick start::

    from jsonschema2020 import Validator, loads

    schema = loads('{"type": "integer", "minimum": 1}')
    validator = Validator(schema)
    validator.is_valid(3)     # True
    validator.is_valid(0)     # False

Public API
----------
:class:`Validator`, :func:`validate`
    Compile a schema and check instances against it.
:func:`loads`
    Exact-number JSON parser (``1.0`` and ``1`` are the same number, no floats).
:func:`normalize`, :func:`json_equal`
    Data-model helpers.
:class:`SchemaError`, :class:`RefResolutionError`, :class:`JSONParseError`
    Exceptions.

The implementation uses only the standard library and no third-party or
built-in JSON, regular-expression or schema-validation code: the JSON parser,
the regex engine and the URI machinery are in this package.
"""

from .errors import RefResolutionError, SchemaError
from .jsonparse import JSONParseError, loads
from .jsonvalue import json_equal, normalize
from .validator import Validator, check_document, validate

__version__ = "1.0.0"

__all__ = [
    "Validator",
    "validate",
    "check_document",
    "loads",
    "normalize",
    "json_equal",
    "SchemaError",
    "RefResolutionError",
    "JSONParseError",
    "__version__",
]
