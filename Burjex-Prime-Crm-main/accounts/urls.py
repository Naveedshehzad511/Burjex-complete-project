from django.urls import path

from .views import logout_view, open_account_redirect

urlpatterns = [
    path("logout/", logout_view, name="logout"),
    path("signout/", logout_view, name="accounts-logout"),
    path("open/", open_account_redirect, name="accounts-open-account"),
]

