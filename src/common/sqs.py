import json


def parse_body(record):
    body = record.get("body", "{}")
    return json.loads(body) if isinstance(body, str) else body


def parse_detail(record, envelope=None):
    if envelope is None:
        envelope = parse_body(record)
    detail = envelope.get("detail", "{}")
    return json.loads(detail) if isinstance(detail, str) else detail
