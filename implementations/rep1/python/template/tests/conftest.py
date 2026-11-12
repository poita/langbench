import pytest

from jtemplate import Environment, TemplateError


@pytest.fixture
def render():
    """render(source, context=None, **other_templates) -> str"""

    def _render(source, context=None, **others):
        templates = {"main": source, **others}
        return Environment(templates).render("main", context or {})

    return _render


@pytest.fixture
def error_kind(render):
    """error_kind(source, context=None, **others) -> the error's kind."""

    def _kind(source, context=None, **others):
        with pytest.raises(TemplateError) as info:
            render(source, context, **others)
        return info.value.kind

    return _kind
