import json
from datetime import datetime, timezone, timedelta


def utcnow_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def utcnow_plus_days_epoch(days):
    future = datetime.now(timezone.utc) + timedelta(days=days)
    return int(future.timestamp())


def log_event(stage, pedido_id, message):
    print(json.dumps({
        "stage": stage,
        "pedidoId": str(pedido_id) if pedido_id else None,
        "message": message,
        "timestamp": utcnow_iso()
    }))
