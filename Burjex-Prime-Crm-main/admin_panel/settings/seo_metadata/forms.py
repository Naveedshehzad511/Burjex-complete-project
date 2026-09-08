from django import forms


class SeoMetadataForm(forms.Form):
    page_title_suffix = forms.CharField(required=False, max_length=120)
    default_meta_description = forms.CharField(required=False, max_length=255)
    robots_index = forms.BooleanField(required=False, initial=True)

