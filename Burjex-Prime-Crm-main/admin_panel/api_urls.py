"""Site-root API routes included under /api/integrations/."""

from django.urls import path

from . import match_trader_views

urlpatterns = [
    path(
        "match-trader/test/",
        match_trader_views.api_integrations_match_trader_test,
        name="api-integrations-match-trader-test",
    ),
    path(
        "match-trader/save/",
        match_trader_views.api_integrations_match_trader_save,
        name="api-integrations-match-trader-save",
    ),
    path(
        "match-trader/status/",
        match_trader_views.api_integrations_match_trader_status,
        name="api-integrations-match-trader-status",
    ),
    path(
        "match-trader/map-groups/",
        match_trader_views.api_integrations_match_trader_map_groups,
        name="api-integrations-match-trader-map-groups",
    ),
]
