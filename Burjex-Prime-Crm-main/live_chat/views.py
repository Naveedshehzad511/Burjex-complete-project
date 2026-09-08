from __future__ import annotations

import json
from datetime import datetime

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.db.models import Count
from django.http import Http404, HttpRequest, HttpResponse, JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_http_methods, require_POST

from accounts.models import User
from accounts.permissions import role_required

from .models import (
    ChatAISettings,
    ChatAgent,
    ChatBusinessHours,
    ChatConversation,
    ChatMessage,
    ChatNotificationSettings,
    ChatSettings,
    QuickReply,
    SupportTicket,
    SupportTicketReply,
)


def _bool(request: HttpRequest, key: str) -> bool:
    return request.POST.get(key) == "on"


def _conversation_payload(conv: ChatConversation) -> dict:
    return {
        "id": conv.id,
        "status": conv.status,
        "ticket_number": conv.ticket_number,
        "is_ticket": conv.is_ticket,
        "guest_name": conv.guest_name,
        "guest_email": conv.guest_email,
        "page_url": conv.page_url,
        "updated_at": conv.updated_at.isoformat(),
    }


def _message_payload(msg: ChatMessage) -> dict:
    return {
        "id": msg.id,
        "sender_type": msg.sender_type,
        "text": msg.text,
        "attachment_url": msg.attachment.url if msg.attachment else "",
        "is_typing": msg.is_typing,
        "created_at": msg.created_at.isoformat(),
    }


def _broadcast_chat_event(conversation_id: int, payload: dict) -> None:
    layer = get_channel_layer()
    if not layer:
        return
    async_to_sync(layer.group_send)(
        f"chat_conversation_{conversation_id}",
        {"type": "chat.event", "payload": payload},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def admin_chat_settings(request: HttpRequest) -> HttpResponse:
    settings_obj = ChatSettings.singleton()
    ai = ChatAISettings.singleton()
    bh = ChatBusinessHours.singleton()
    notif = ChatNotificationSettings.singleton()

    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        if action == "delete_quick_reply":
            qr = QuickReply.objects.filter(id=request.POST.get("quick_reply_id")).first()
            if qr:
                qr.delete()
                messages.success(request, "Quick reply deleted.")
            return redirect("admin-chat-settings")

        settings_obj.enable_live_chat = _bool(request, "enable_live_chat")
        settings_obj.show_on_public_pages = _bool(request, "show_on_public_pages")
        settings_obj.auto_assign_conversations = _bool(request, "auto_assign_conversations")
        settings_obj.enable_attachments = _bool(request, "enable_attachments")
        settings_obj.show_typing_indicator = _bool(request, "show_typing_indicator")
        settings_obj.missed_chat_timeout_seconds = int(request.POST.get("missed_chat_timeout_seconds", 120) or 120)
        settings_obj.idle_timeout_seconds = int(request.POST.get("idle_timeout_seconds", 300) or 300)
        settings_obj.max_concurrent_chats = int(request.POST.get("max_concurrent_chats", 10) or 10)
        settings_obj.enable_welcome_message = _bool(request, "enable_welcome_message")
        settings_obj.welcome_message_text = request.POST.get("welcome_message_text", "").strip()
        settings_obj.welcome_delay_seconds = int(request.POST.get("welcome_delay_seconds", 2) or 2)
        settings_obj.enable_offline_message = _bool(request, "enable_offline_message")
        settings_obj.offline_message_text = request.POST.get("offline_message_text", "").strip()
        settings_obj.offline_delay_seconds = int(request.POST.get("offline_delay_seconds", 2) or 2)
        settings_obj.collect_email_when_offline = _bool(request, "collect_email_when_offline")
        settings_obj.enable_away_message = _bool(request, "enable_away_message")
        settings_obj.away_message_text = request.POST.get("away_message_text", "").strip()
        settings_obj.away_delay_seconds = int(request.POST.get("away_delay_seconds", 2) or 2)
        settings_obj.enable_end_message = _bool(request, "enable_end_message")
        settings_obj.end_message_text = request.POST.get("end_message_text", "").strip()
        settings_obj.end_delay_seconds = int(request.POST.get("end_delay_seconds", 1) or 1)
        settings_obj.widget_color = request.POST.get("widget_color", "#0B3C5D").strip() or "#0B3C5D"
        settings_obj.text_color = request.POST.get("text_color", "#FFFFFF").strip() or "#FFFFFF"
        settings_obj.background_color = request.POST.get("background_color", "#FFFFFF").strip() or "#FFFFFF"
        settings_obj.widget_position = request.POST.get("widget_position", ChatSettings.WidgetPosition.BOTTOM_RIGHT)
        settings_obj.custom_position_css = request.POST.get("custom_position_css", "").strip()
        settings_obj.button_size_px = int(request.POST.get("button_size_px", 56) or 56)
        settings_obj.offset_x_px = int(request.POST.get("offset_x_px", 24) or 24)
        settings_obj.offset_y_px = int(request.POST.get("offset_y_px", 24) or 24)
        settings_obj.widget_title = request.POST.get("widget_title", "Live Chat").strip() or "Live Chat"
        settings_obj.widget_subtitle = request.POST.get("widget_subtitle", "Chat with our support team").strip()
        settings_obj.show_agent_photo = _bool(request, "show_agent_photo")
        settings_obj.auto_open = _bool(request, "auto_open")
        settings_obj.show_on_mobile = _bool(request, "show_on_mobile")
        settings_obj.sound_notifications = _bool(request, "sound_notifications")
        settings_obj.guest_info_collection = _bool(request, "guest_info_collection")
        settings_obj.conversation_persistence = _bool(request, "conversation_persistence")
        settings_obj.source_tracking = _bool(request, "source_tracking")
        settings_obj.embed_widget_enabled = _bool(request, "embed_widget_enabled")
        settings_obj.save()

        ai.response_tone = request.POST.get("response_tone", "warm").strip() or "warm"
        ai.max_response_length = int(request.POST.get("max_response_length", 400) or 400)
        ai.creativity_temperature = request.POST.get("creativity_temperature", "0.30") or "0.30"
        ai.include_user_info = _bool(request, "include_user_info")
        ai.include_page_url = _bool(request, "include_page_url")
        ai.recent_messages_count = int(request.POST.get("recent_messages_count", 10) or 10)
        ai.system_role = request.POST.get("system_role", "Support assistant").strip() or "Support assistant"
        ai.ai_instructions = request.POST.get("ai_instructions", "").strip()
        ai.auto_suggest_replies = _bool(request, "auto_suggest_replies")
        ai.knowledge_base = request.POST.get("knowledge_base", "").strip()
        ai.enabled = _bool(request, "ai_enabled")
        ai.save()

        bh.timezone = request.POST.get("timezone", "UTC").strip() or "UTC"
        bh.mon_enabled = _bool(request, "mon_enabled")
        bh.tue_enabled = _bool(request, "tue_enabled")
        bh.wed_enabled = _bool(request, "wed_enabled")
        bh.thu_enabled = _bool(request, "thu_enabled")
        bh.fri_enabled = _bool(request, "fri_enabled")
        bh.sat_enabled = _bool(request, "sat_enabled")
        bh.sun_enabled = _bool(request, "sun_enabled")
        bh.start_time = request.POST.get("start_time", "09:00") or "09:00"
        bh.end_time = request.POST.get("end_time", "18:00") or "18:00"
        bh.mon_start_time = request.POST.get("mon_start_time", "09:00") or "09:00"
        bh.mon_end_time = request.POST.get("mon_end_time", "18:00") or "18:00"
        bh.tue_start_time = request.POST.get("tue_start_time", "09:00") or "09:00"
        bh.tue_end_time = request.POST.get("tue_end_time", "18:00") or "18:00"
        bh.wed_start_time = request.POST.get("wed_start_time", "09:00") or "09:00"
        bh.wed_end_time = request.POST.get("wed_end_time", "18:00") or "18:00"
        bh.thu_start_time = request.POST.get("thu_start_time", "09:00") or "09:00"
        bh.thu_end_time = request.POST.get("thu_end_time", "18:00") or "18:00"
        bh.fri_start_time = request.POST.get("fri_start_time", "09:00") or "09:00"
        bh.fri_end_time = request.POST.get("fri_end_time", "18:00") or "18:00"
        bh.sat_start_time = request.POST.get("sat_start_time", "09:00") or "09:00"
        bh.sat_end_time = request.POST.get("sat_end_time", "18:00") or "18:00"
        bh.sun_start_time = request.POST.get("sun_start_time", "09:00") or "09:00"
        bh.sun_end_time = request.POST.get("sun_end_time", "18:00") or "18:00"
        bh.offline_detection = _bool(request, "offline_detection")
        bh.save()

        notif.new_chat_sound = _bool(request, "new_chat_sound")
        notif.new_message_sound = _bool(request, "new_message_sound")
        notif.volume_percent = int(request.POST.get("volume_percent", 80) or 80)
        notif.enable_browser_notifications = _bool(request, "enable_browser_notifications")
        notif.agent_online_alert = _bool(request, "agent_online_alert")
        notif.agent_offline_alert = _bool(request, "agent_offline_alert")
        notif.queue_threshold_alert = _bool(request, "queue_threshold_alert")
        notif.queue_threshold_number = int(request.POST.get("queue_threshold_number", 5) or 5)
        notif.save()

        if action in {"save", "quick_reply_save"} and request.POST.get("quick_reply_submit") == "1" and (
            request.POST.get("qr_title") or request.POST.get("qr_slash_command") or request.POST.get("qr_message")
        ):
            quick_reply_id = request.POST.get("quick_reply_id")
            if quick_reply_id:
                qr = get_object_or_404(QuickReply, pk=quick_reply_id)
            else:
                qr = QuickReply()
            qr.title = request.POST.get("qr_title", "").strip()
            qr.slash_command = request.POST.get("qr_slash_command", "").strip().lower()
            qr.message = request.POST.get("qr_message", "").strip()
            qr.category = request.POST.get("qr_category", QuickReply.Categories.RESPONSES)
            qr.is_active = _bool(request, "qr_is_active")
            qr.save()
            messages.success(request, "Quick reply saved.")
        messages.success(request, "Chat settings updated successfully.")
        return redirect("admin-chat-settings")

    quick_replies = QuickReply.objects.all()
    return render(
        request,
        "admin_panel/chat_settings.html",
        {"s": settings_obj, "ai": ai, "bh": bh, "n": notif, "quick_replies": quick_replies},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_GET
def admin_tickets_dashboard(request: HttpRequest) -> HttpResponse:
    active_tab = (request.GET.get("tab") or SupportTicket.Status.PENDING).upper()
    valid_tabs = {x for x, _ in SupportTicket.Status.choices}
    if active_tab not in valid_tabs:
        active_tab = SupportTicket.Status.PENDING
    tickets = (
        SupportTicket.objects.select_related("user")
        .filter(status=active_tab)
        .order_by("-updated_at", "-id")[:200]
    )
    selected = tickets[0] if tickets else None
    if request.GET.get("ticket_id"):
        selected = get_object_or_404(SupportTicket.objects.select_related("user"), pk=request.GET["ticket_id"])
    replies = selected.replies.select_related("sender").all() if selected else []
    counts = {k: 0 for k, _ in SupportTicket.Status.choices}
    for row in SupportTicket.objects.values("status").annotate(total=Count("id")):
        counts[row["status"]] = row["total"]
    return render(
        request,
        "admin_panel/chat_tickets_dashboard.html",
        {
            "active_tab": active_tab,
            "tickets": tickets,
            "selected": selected,
            "replies": replies,
            "counts": counts,
            "status_choices": SupportTicket.Status.choices,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_POST
def admin_send_message(request: HttpRequest, conversation_id: int) -> HttpResponse:
    ticket = get_object_or_404(SupportTicket, pk=conversation_id)
    text = (request.POST.get("text") or "").strip()
    attachment = request.FILES.get("attachment")
    if not text and not attachment:
        return redirect(f"{reverse('admin-tickets')}?tab={ticket.status}&ticket_id={ticket.id}")
    SupportTicketReply.objects.create(ticket=ticket, sender=request.user, is_admin=True, message=text[:5000], attachment=attachment)
    if ticket.status == SupportTicket.Status.PENDING:
        ticket.status = SupportTicket.Status.OPEN
    elif ticket.status == SupportTicket.Status.OPEN:
        ticket.status = SupportTicket.Status.IN_PROGRESS
    ticket.read_by_admin = True
    ticket.save(update_fields=["status", "read_by_admin", "updated_at"])
    return redirect(f"{reverse('admin-tickets')}?tab={ticket.status}&ticket_id={ticket.id}")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_POST
def admin_ticket_update_status(request: HttpRequest, ticket_id: int) -> HttpResponse:
    ticket = get_object_or_404(SupportTicket, pk=ticket_id)
    action = (request.POST.get("action") or "").strip().lower()
    now = timezone.now()
    if action == "read":
        ticket.read_by_admin = True
        if ticket.status == SupportTicket.Status.PENDING:
            ticket.status = SupportTicket.Status.OPEN
        ticket.save(update_fields=["read_by_admin", "status", "updated_at"])
    elif action == "resolve":
        ticket.status = SupportTicket.Status.RESOLVED
        ticket.read_by_admin = True
        ticket.resolved_at = now
        ticket.save(update_fields=["status", "read_by_admin", "resolved_at", "updated_at"])
    elif action == "close":
        ticket.status = SupportTicket.Status.CLOSED
        ticket.read_by_admin = True
        ticket.closed_at = now
        ticket.save(update_fields=["status", "read_by_admin", "closed_at", "updated_at"])
    tab = (request.POST.get("tab") or ticket.status).upper()
    return redirect(f"{reverse('admin-tickets')}?tab={tab}&ticket_id={ticket.id}")


@require_GET
def widget_js(request: HttpRequest) -> HttpResponse:
    js = """
(function(){
  if (window.__crmLiveChatLoaded) return;
  window.__crmLiveChatLoaded = true;
  var API = "/chat/api";
  var state = { open:false, conversationId:null, lastMessageId:0, config:null };
  function el(tag, attrs){ var n=document.createElement(tag); if(attrs){Object.keys(attrs).forEach(function(k){n.setAttribute(k, attrs[k]);});} return n; }
  function byId(id){ return document.getElementById(id); }
  function req(path, opts){ return fetch(API + path, Object.assign({headers:{'Content-Type':'application/json'}}, opts||{})).then(function(r){return r.json();}); }
  function ensureUI(cfg){
    if (byId("crm-chat-btn")) return;
    var btn = el("button", {id:"crm-chat-btn", type:"button"});
    btn.textContent = "Chat";
    btn.style.cssText = "position:fixed;z-index:99999;border:none;border-radius:999px;padding:0 18px;height:"+cfg.button_size_px+"px;background:"+cfg.widget_color+";color:"+cfg.text_color+";cursor:pointer;font-weight:600;";
    if (cfg.widget_position === "BOTTOM_LEFT") { btn.style.left = cfg.offset_x_px + "px"; btn.style.bottom = cfg.offset_y_px + "px"; }
    else { btn.style.right = cfg.offset_x_px + "px"; btn.style.bottom = cfg.offset_y_px + "px"; }
    var panel = el("div",{id:"crm-chat-panel"});
    panel.style.cssText = "display:none;position:fixed;z-index:99999;width:340px;max-width:96vw;height:460px;max-height:88vh;background:"+cfg.background_color+";border:1px solid #dbe2ea;border-radius:14px;box-shadow:0 12px 34px rgba(15,23,42,.2);overflow:hidden;";
    if (cfg.widget_position === "BOTTOM_LEFT") { panel.style.left = cfg.offset_x_px + "px"; panel.style.bottom = (cfg.offset_y_px + cfg.button_size_px + 12) + "px"; }
    else { panel.style.right = cfg.offset_x_px + "px"; panel.style.bottom = (cfg.offset_y_px + cfg.button_size_px + 12) + "px"; }
    panel.innerHTML = '<div style="padding:12px 14px;background:'+cfg.widget_color+';color:'+cfg.text_color+';"><div style="font-weight:700;">'+cfg.widget_title+'</div><div style="font-size:12px;opacity:.9;">'+(cfg.widget_subtitle||"")+'</div></div><div id="crm-chat-messages" style="height:320px;overflow:auto;padding:10px;background:#fff"></div><form id="crm-chat-form" style="display:flex;gap:8px;padding:10px;border-top:1px solid #e5e7eb;"><input id="crm-chat-input" placeholder="Type your message..." style="flex:1;border:1px solid #d1d5db;border-radius:8px;padding:8px;"><button style="border:none;border-radius:8px;padding:8px 12px;background:'+cfg.widget_color+';color:'+cfg.text_color+';">Send</button></form>';
    document.body.appendChild(btn); document.body.appendChild(panel);
    btn.addEventListener("click", function(){ state.open = !state.open; panel.style.display = state.open ? "block" : "none"; if(state.open){ initConversation(); } });
    byId("crm-chat-form").addEventListener("submit", function(e){ e.preventDefault(); sendMessage(); });
  }
  function appendMessage(m){
    var box = byId("crm-chat-messages"); if(!box) return;
    var div = document.createElement("div");
    div.style.cssText = "margin:6px 0;display:flex;justify-content:" + ((m.sender_type==="AGENT"||m.sender_type==="AI"||m.sender_type==="SYSTEM")?"flex-start":"flex-end") + ";";
    var b = document.createElement("div");
    b.textContent = m.text || "";
    b.style.cssText = "max-width:80%;padding:8px 10px;border-radius:10px;font-size:13px;white-space:pre-wrap;background:" + ((m.sender_type==="AGENT"||m.sender_type==="AI"||m.sender_type==="SYSTEM")?"#eef2ff":"#0B3C5D") + ";color:" + ((m.sender_type==="AGENT"||m.sender_type==="AI"||m.sender_type==="SYSTEM")?"#0f172a":"#fff") + ";";
    div.appendChild(b); box.appendChild(div); box.scrollTop = box.scrollHeight;
  }
  function initConversation(){
      if (state.conversationId) return;
    req("/conversations/start/", {method:"POST", body: JSON.stringify({page_url:window.location.href})}).then(function(res){
      if(!res.ok) return;
      state.conversationId = res.conversation_id;
        try {
          var scheme = window.location.protocol === "https:" ? "wss://" : "ws://";
          var ws = new WebSocket(scheme + window.location.host + "/ws/chat/conversations/" + state.conversationId + "/");
          ws.onmessage = function(e){
            try {
              var payload = JSON.parse(e.data || "{}");
              if (payload.type === "new_message" && payload.message) {
                state.lastMessageId = Math.max(state.lastMessageId, payload.message.id || 0);
                appendMessage(payload.message);
              }
            } catch (_err) {}
          };
        } catch (_wsErr) {}
      if (res.welcome_message) appendMessage({sender_type:"SYSTEM", text:res.welcome_message});
      pollMessages();
    });
  }
  function pollMessages(){
    if(!state.conversationId) return;
    req("/conversations/"+state.conversationId+"/messages/?after_id="+state.lastMessageId).then(function(res){
      if(!res.ok) return;
      (res.messages||[]).forEach(function(m){ state.lastMessageId = Math.max(state.lastMessageId, m.id); appendMessage(m); });
      setTimeout(pollMessages, 1500);
    }).catch(function(){ setTimeout(pollMessages, 2500); });
  }
  function sendMessage(){
    var i = byId("crm-chat-input"); if(!i || !i.value.trim() || !state.conversationId) return;
    var txt = i.value.trim(); i.value = "";
    req("/conversations/"+state.conversationId+"/messages/send/", {method:"POST", body: JSON.stringify({text:txt})}).then(function(res){ if(res.ok && res.message){ appendMessage(res.message); } });
  }
  req("/settings/").then(function(res){
    if(!res.ok || !res.settings || !res.settings.enable_live_chat) return;
    ensureUI(res.settings);
    if (res.settings.auto_open) byId("crm-chat-btn").click();
  });
})();
"""
    return HttpResponse(js, content_type="application/javascript")


@require_GET
def api_settings(request: HttpRequest) -> JsonResponse:
    s = ChatSettings.singleton()
    if not s.embed_widget_enabled:
        return JsonResponse({"ok": True, "settings": {"enable_live_chat": False}})
    if not s.show_on_mobile and "Mobile" in request.META.get("HTTP_USER_AGENT", ""):
        return JsonResponse({"ok": True, "settings": {"enable_live_chat": False}})
    return JsonResponse(
        {
            "ok": True,
            "settings": {
                "enable_live_chat": s.enable_live_chat,
                "show_on_public_pages": s.show_on_public_pages,
                "button_size_px": s.button_size_px,
                "widget_color": s.widget_color,
                "text_color": s.text_color,
                "background_color": s.background_color,
                "widget_position": s.widget_position,
                "offset_x_px": s.offset_x_px,
                "offset_y_px": s.offset_y_px,
                "widget_title": s.widget_title,
                "widget_subtitle": s.widget_subtitle,
                "auto_open": s.auto_open,
            },
        }
    )


@csrf_exempt
@require_POST
def api_conversation_start(request: HttpRequest) -> JsonResponse:
    s = ChatSettings.singleton()
    if not s.enable_live_chat:
        return JsonResponse({"ok": False, "error": "Live chat disabled"}, status=400)
    if not request.session.session_key:
        request.session.create()
    try:
        payload = json.loads(request.body or b"{}")
    except (json.JSONDecodeError, UnicodeDecodeError):
        return JsonResponse({"ok": False, "error": "Invalid JSON body"}, status=400)
    if not isinstance(payload, dict):
        payload = {}
    conversation = ChatConversation.objects.create(
        user=request.user if request.user.is_authenticated else None,
        session_key=request.session.session_key or "",
        guest_name=(payload.get("guest_name") or "")[:120],
        guest_email=(payload.get("guest_email") or "")[:255],
        page_url=(payload.get("page_url") or "")[:500],
        source=(payload.get("source") or "website")[:80],
        status=ChatConversation.Status.QUEUED,
    )
    welcome_message = ""
    if s.enable_welcome_message and s.welcome_message_text:
        welcome_message = s.welcome_message_text
    return JsonResponse({"ok": True, "conversation_id": conversation.id, "welcome_message": welcome_message})


def _fetch_conversation_for_request(request: HttpRequest, conversation_id: int) -> ChatConversation:
    conversation = get_object_or_404(ChatConversation, pk=conversation_id)
    if request.user.is_authenticated and request.user.role in {User.Roles.ADMIN, User.Roles.BANKER}:
        return conversation
    if request.user.is_authenticated and conversation.user_id == request.user.id:
        return conversation
    if request.session.session_key and conversation.session_key == request.session.session_key:
        return conversation
    raise Http404("Conversation not found")


@require_GET
def api_messages_list(request: HttpRequest, conversation_id: int) -> JsonResponse:
    conv = _fetch_conversation_for_request(request, conversation_id)
    after_id = int(request.GET.get("after_id", 0) or 0)
    qs = conv.messages.filter(id__gt=after_id).select_related("sender_user")[:100]
    return JsonResponse({"ok": True, "conversation": _conversation_payload(conv), "messages": [_message_payload(m) for m in qs]})


@csrf_exempt
@require_POST
def api_messages_send(request: HttpRequest, conversation_id: int) -> JsonResponse:
    conv = _fetch_conversation_for_request(request, conversation_id)
    was_ticket = bool(conv.is_ticket)
    s = ChatSettings.singleton()
    try:
        payload = json.loads(request.body or b"{}")
    except (json.JSONDecodeError, UnicodeDecodeError):
        return JsonResponse({"ok": False, "error": "Invalid JSON body"}, status=400)
    if not isinstance(payload, dict):
        payload = {}
    text = (payload.get("text") or "").strip()
    if not text:
        return JsonResponse({"ok": False, "error": "Message text is required"}, status=400)

    sender_type = ChatMessage.SenderType.GUEST
    sender_user = None
    if request.user.is_authenticated and request.user.role in {User.Roles.ADMIN, User.Roles.BANKER}:
        sender_type = ChatMessage.SenderType.AGENT
        sender_user = request.user
    elif request.user.is_authenticated:
        sender_type = ChatMessage.SenderType.CLIENT
        sender_user = request.user

    msg = ChatMessage.objects.create(
        conversation=conv,
        sender_user=sender_user,
        sender_type=sender_type,
        text=text[:5000],
    )
    conv.status = ChatConversation.Status.ACTIVE
    conv.unread_for_admin = sender_type in {ChatMessage.SenderType.GUEST, ChatMessage.SenderType.CLIENT}
    conv.unread_for_client = sender_type == ChatMessage.SenderType.AGENT
    if conv.unread_for_admin and s.missed_chat_timeout_seconds > 0:
        elapsed = timezone.now() - conv.started_at
        if elapsed.total_seconds() >= s.missed_chat_timeout_seconds and conv.status != ChatConversation.Status.CLOSED:
            conv.is_ticket = True
            if not conv.ticket_number:
                conv.ticket_number = f"TKT-{conv.id}-{datetime.utcnow().strftime('%Y%m%d')}"
    conv.save()
    if conv.is_ticket and not was_ticket:
        try:
            from enterprise.staff_notify import broadcast_staff_notification

            ttok = f"[ticket_escalate:{conv.id}]"
            broadcast_staff_notification(
                "Support ticket escalated",
                f"{ttok} Conversation #{conv.id} marked as ticket ({conv.ticket_number or 'pending'}).",
                action_url=reverse("admin-tickets"),
                dedupe_body_contains=ttok,
            )
        except Exception:
            pass
    _broadcast_chat_event(conv.id, {"type": "new_message", "message": _message_payload(msg)})
    ai_message_payload = None
    ai_cfg = ChatAISettings.singleton()
    if ai_cfg.enabled and sender_type in {ChatMessage.SenderType.GUEST, ChatMessage.SenderType.CLIENT}:
        ai_text = (
            f"Thanks for your message. We understand you asked: \"{text[:140]}\". "
            "Our support team will assist you shortly."
        )[: ai_cfg.max_response_length]
        ai_msg = ChatMessage.objects.create(
            conversation=conv,
            sender_type=ChatMessage.SenderType.AI,
            text=ai_text,
        )
        ai_message_payload = _message_payload(ai_msg)
        _broadcast_chat_event(conv.id, {"type": "new_message", "message": ai_message_payload})
    return JsonResponse(
        {
            "ok": True,
            "message": _message_payload(msg),
            "ai_message": ai_message_payload,
            "conversation": _conversation_payload(conv),
        }
    )


@csrf_exempt
@require_POST
def api_conversation_close(request: HttpRequest, conversation_id: int) -> JsonResponse:
    conv = _fetch_conversation_for_request(request, conversation_id)
    conv.status = ChatConversation.Status.CLOSED
    conv.ended_at = timezone.now()
    if not conv.ticket_number and conv.is_ticket:
        conv.ticket_number = f"TKT-{conv.id}-{timezone.now().strftime('%Y%m%d')}"
    conv.save(update_fields=["status", "ended_at", "ticket_number", "updated_at"])
    end_message = ChatSettings.singleton().end_message_text
    if end_message:
        ChatMessage.objects.create(conversation=conv, sender_type=ChatMessage.SenderType.SYSTEM, text=end_message)
    _broadcast_chat_event(conv.id, {"type": "conversation_closed"})
    return JsonResponse({"ok": True})


@require_GET
def api_quick_replies(request: HttpRequest) -> JsonResponse:
    replies = QuickReply.objects.filter(is_active=True).values("id", "title", "slash_command", "message", "category")
    return JsonResponse({"ok": True, "quick_replies": list(replies)})

