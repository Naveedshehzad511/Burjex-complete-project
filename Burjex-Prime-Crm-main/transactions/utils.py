from django.db import IntegrityError
from transactions.models import ProcessedAction

def ensure_unique_action(unique_id: str, action_type: str):
    """
    Attempts to register the unique_id.
    Raises ValueError if the transaction has already been processed.
    """
    try:
        ProcessedAction.objects.create(unique_id=unique_id, action_type=action_type)
    except IntegrityError:
        raise ValueError("This transaction has already been processed.")
