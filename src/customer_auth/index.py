import os
import json
import uuid
import boto3
from botocore.exceptions import ClientError
from common.auth import hash_password, verify_password, create_jwt, decode_jwt
from common.http import api_response, error_response

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])
JWT_SECRET = os.environ["JWT_SECRET"]


def lambda_handler(event, context):
    resource = event.get("resource", "")
    if resource == "/customers/register":
        return register_handler(event, context)
    if resource == "/customers/login":
        return login_handler(event, context)
    if resource == "/customers/me":
        return me_handler(event, context)
    return error_response(404, "Not found")


def register_handler(event, context):
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return error_response(400, "Invalid JSON body")
    email = body.get("email", "").strip()
    password = body.get("password", "")
    if not email or not password:
        return error_response(400, "email and password are required")
    cliente_id = "CUST-" + uuid.uuid4().hex[:12]
    salt_hex, hash_hex = hash_password(password)
    try:
        table.put_item(
            Item={
                "email": email,
                "clienteId": cliente_id,
                "salt": salt_hex,
                "hash": hash_hex,
            },
            ConditionExpression="attribute_not_exists(email)",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return error_response(409, "Email already registered")
        raise
    return api_response(201, {"clienteId": cliente_id, "email": email})


def login_handler(event, context):
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return error_response(400, "Invalid JSON body")
    email = body.get("email", "").strip()
    password = body.get("password", "")
    if not email or not password:
        return error_response(400, "email and password are required")
    result = table.get_item(Key={"email": email})
    item = result.get("Item")
    if not item or not verify_password(password, item["salt"], item["hash"]):
        return error_response(401, "Invalid credentials")
    token = create_jwt(
        {"clienteId": item["clienteId"], "email": email},
        JWT_SECRET,
        86400,
    )
    return api_response(200, {
        "token": token,
        "clienteId": item["clienteId"],
        "expiresIn": 86400,
    })


def me_handler(event, context):
    auth_header = event.get("headers", {}).get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return error_response(401, "Missing or invalid Authorization header")
    token = auth_header[7:]
    try:
        payload = decode_jwt(token, JWT_SECRET)
    except ValueError as e:
        return error_response(401, str(e))
    return api_response(200, {
        "clienteId": payload["clienteId"],
        "email": payload["email"],
    })
