from marketing.models import MarketingCampaign


WEBSITE_FUNNEL_CAMPAIGN_NAME = "Website Funnel"


def get_or_create_website_funnel_campaign() -> MarketingCampaign:
    campaign, _ = MarketingCampaign.objects.get_or_create(
        name=WEBSITE_FUNNEL_CAMPAIGN_NAME,
        defaults={"description": "Default campaign for visitor capture and funnel leads.", "is_active": True},
    )
    return campaign
