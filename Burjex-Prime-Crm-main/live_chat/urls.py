from django.urls import path

from . import views

urlpatterns = [
    path("widget.js", views.widget_js, name="chat-widget-js"),
    path("api/settings/", views.api_settings, name="chat-api-settings"),
    path("api/quick-replies/", views.api_quick_replies, name="chat-api-quick-replies"),
    path("api/conversations/start/", views.api_conversation_start, name="chat-api-conversation-start"),
    path("api/conversations/<int:conversation_id>/messages/", views.api_messages_list, name="chat-api-messages-list"),
    path(
        "api/conversations/<int:conversation_id>/messages/send/",
        views.api_messages_send,
        name="chat-api-messages-send",
    ),
    path(
        "api/conversations/<int:conversation_id>/close/",
        views.api_conversation_close,
        name="chat-api-conversation-close",
    ),
]

