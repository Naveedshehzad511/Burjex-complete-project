from django import template
from django.urls import NoReverseMatch, reverse

register = template.Library()


@register.simple_tag
def safe_url(viewname, *args, **kwargs):
    """Resolve a named URL; return '#' if the name is missing (avoids NoReverseMatch in templates)."""
    try:
        return reverse(viewname, args=args, kwargs=kwargs)
    except NoReverseMatch:
        return "#"
