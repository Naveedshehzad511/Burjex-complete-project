from __future__ import annotations

from rest_framework import serializers

from accounts.models import User


class UserSerializer(serializers.ModelSerializer):
    display_name = serializers.SerializerMethodField()
    is_verified = serializers.BooleanField(read_only=True)
    avatar_url = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = [
            "id",
            "username",
            "email",
            "first_name",
            "last_name",
            "display_name",
            "phone",
            "country",
            "address",
            "role",
            "account_status",
            "kyc_status",
            "kyc_identity_front_status",
            "kyc_identity_back_status",
            "kyc_address_status",
            "kyc_final_status",
            "email_verified",
            "phone_verified",
            "wallet_balance",
            "pending_withdraw",
            "referral_code",
            "ftd_user",
            "totp_enabled",
            "force_password_change",
            "is_verified",
            "avatar_url",
            "date_joined",
            "last_login",
        ]
        read_only_fields = fields

    def get_display_name(self, obj: User) -> str:
        return obj.display_name()

    def get_avatar_url(self, obj: User) -> str | None:
        if not obj.avatar:
            return None
        request = self.context.get("request")
        url = obj.avatar.url
        if request:
            return request.build_absolute_uri(url)
        return url
