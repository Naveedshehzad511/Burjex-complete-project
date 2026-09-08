from __future__ import annotations

from .models import ChatSettings


def live_chat_widget_context(request):
    is_admin = request.path.startswith("/admin/")
    show = False
    try:
        settings_obj = ChatSettings.singleton()
        show = settings_obj.enable_live_chat and settings_obj.show_on_public_pages and not is_admin
    except Exception:
        show = False
    return {"show_live_chat_widget": show}

