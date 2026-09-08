from django.conf import settings
from django.http import HttpResponseRedirect
from django.shortcuts import redirect
from django.utils import translation
from django.views.decorators.http import require_GET


@require_GET
def set_language_prefix(request, lang_code: str):
    allowed = {code for code, _ in getattr(settings, "LANGUAGES", [])}
    if lang_code not in allowed:
        return redirect("/")
    request.session[translation.LANGUAGE_SESSION_KEY] = lang_code
    next_url = request.GET.get("next") or request.META.get("HTTP_REFERER") or "/"
    response = HttpResponseRedirect(next_url)
    response.set_cookie(settings.LANGUAGE_COOKIE_NAME, lang_code)
    return response
