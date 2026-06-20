from datetime import datetime, timezone


def utcnow_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
