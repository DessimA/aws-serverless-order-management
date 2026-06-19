from datetime import datetime


def utcnow_iso():
    return datetime.utcnow().isoformat() + "Z"


def generate_id(prefix="ORD-"):
    return f"{prefix}{datetime.utcnow().timestamp()}"
