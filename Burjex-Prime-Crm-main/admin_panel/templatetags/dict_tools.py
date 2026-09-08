from django import template

register = template.Library()


@register.filter
def dict_get(mapping, key):
    if mapping is None:
        return ""
    return mapping.get(str(key), "")


@register.filter
def format_ib_answer(val):
    if isinstance(val, list):
        return ", ".join(str(x) for x in val)
    return val


@register.filter
def contains_choice(cur, opt):
    if isinstance(cur, list):
        return opt in cur
    if cur is None or cur == "":
        return False
    return str(cur) == str(opt)
