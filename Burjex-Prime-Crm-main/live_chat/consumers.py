from __future__ import annotations

import json

from asgiref.sync import sync_to_async
from channels.generic.websocket import AsyncWebsocketConsumer

from accounts.models import User

from .models import ChatConversation


class ConversationConsumer(AsyncWebsocketConsumer):
    async def connect(self):
        self.conversation_id = int(self.scope["url_route"]["kwargs"]["conversation_id"])
        self.group_name = f"chat_conversation_{self.conversation_id}"
        if not await self._can_access():
            await self.close(code=4404)
            return
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()

    async def disconnect(self, close_code):
        await self.channel_layer.group_discard(self.group_name, self.channel_name)

    async def receive(self, text_data=None, bytes_data=None):
        # Incoming messages are handled by HTTP APIs; websocket is used for realtime push.
        return

    async def chat_event(self, event):
        await self.send(text_data=json.dumps(event["payload"]))

    @sync_to_async
    def _can_access(self) -> bool:
        try:
            conv = ChatConversation.objects.get(pk=self.conversation_id)
        except ChatConversation.DoesNotExist:
            return False
        user = self.scope.get("user")
        if user and user.is_authenticated and user.role in {User.Roles.ADMIN, User.Roles.BANKER}:
            return True
        if user and user.is_authenticated and conv.user_id == user.id:
            return True
        session = self.scope.get("session")
        if session and session.session_key and conv.session_key == session.session_key:
            return True
        return False

