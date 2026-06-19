import json

CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}


def api_response(status_code, body, headers=None):
    return {
        "statusCode": status_code,
        "headers": headers or CORS_HEADERS,
        "body": json.dumps(body),
    }


def error_response(status_code, message, headers=None):
    return api_response(status_code, {"error": message}, headers)
