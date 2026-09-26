from django.apps import AppConfig


class AccountsConfig(AppConfig):
    name = 'accounts'

    def ready(self):
        from accounts import push  # noqa: F401  (registers the deposit/withdrawal push signal)
