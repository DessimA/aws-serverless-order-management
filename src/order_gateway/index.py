import os
import json
import boto3
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key
from common.auth import decode_jwt
from common.http import api_response, error_response

table = boto3.resource("dynamodb").Table(os.environ["DYNAMODB_TABLE"])
eventbridge = boto3.client("events")
JWT_SECRET = os.environ["JWT_SECRET"]


def _require_auth(event):
    auth_header = event.get("headers", {}).get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return None, error_response(401, "Missing or invalid Authorization header")
    token = auth_header[7:]
    try:
        payload = decode_jwt(token, JWT_SECRET)
        return payload, None
    except ValueError as e:
        return None, error_response(401, str(e))


def _get_owned_order(order_id, client_id):
    try:
        result = table.get_item(Key={"orderId": str(order_id)})
        item = result.get("Item")
        if not item or item.get("clientId") != client_id:
            return None, error_response(404, "Order not found")
        return item, None
    except ClientError as e:
        print(f"DynamoDB ClientError: {e}")
        return None, error_response(500, "Internal server error")


def list_handler(event, context):
    payload, err = _require_auth(event)
    if err:
        return err
    client_id = payload["clienteId"]
    try:
        items = []
        kwargs = {
            "IndexName": "clientId-index",
            "KeyConditionExpression": Key("clientId").eq(client_id),
        }
        while True:
            result = table.query(**kwargs)
            items.extend(result.get("Items", []))
            last_key = result.get("LastEvaluatedKey")
            if not last_key:
                break
            kwargs["ExclusiveStartKey"] = last_key
        return api_response(200, {"orders": items, "count": len(items)})
    except ClientError as e:
        print(f"DynamoDB ClientError querying orders: {e}")
        return error_response(500, "Internal server error")


def get_handler(event, context):
    payload, err = _require_auth(event)
    if err:
        return err
    params = event.get("pathParameters") or {}
    order_id = params.get("orderId")
    if not order_id:
        return error_response(400, "Missing orderId")
    item, err = _get_owned_order(order_id, payload["clienteId"])
    if err:
        return err
    return api_response(200, item)


def cancel_handler(event, context):
    payload, err = _require_auth(event)
    if err:
        return err
    params = event.get("pathParameters") or {}
    order_id = params.get("orderId")
    if not order_id:
        return error_response(400, "Missing orderId")
    item, err = _get_owned_order(order_id, payload["clienteId"])
    if err:
        return err
    if item.get("status") == "CANCELLED":
        return error_response(409, "Order is already cancelled")
    detail = json.dumps({"pedidoId": order_id})
    try:
        response = eventbridge.put_events(
            Entries=[{
                "Source": "app.orders.operations",
                "DetailType": "OrderCancelled",
                "Detail": detail,
                "EventBusName": os.environ["EVENT_BUS_NAME"],
            }]
        )
    except Exception as e:
        print(f"EventBridge error on cancel: {str(e)}")
        return error_response(500, "Failed to publish cancellation event")
    if response.get("FailedEntryCount", 0) > 0:
        print(f"Failed to publish cancellation event: {response}")
        return error_response(500, "Failed to publish cancellation event")
    return api_response(202, {"status": "Cancellation requested", "orderId": order_id})


def update_handler(event, context):
    payload, err = _require_auth(event)
    if err:
        return err
    params = event.get("pathParameters") or {}
    order_id = params.get("orderId")
    if not order_id:
        return error_response(400, "Missing orderId")
    item, err = _get_owned_order(order_id, payload["clienteId"])
    if err:
        return err
    if item.get("status") == "CANCELLED":
        return error_response(409, "Cannot update a cancelled order")
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return error_response(400, "Invalid JSON body")
    novos_itens = body.get("novosItens")
    if not novos_itens or not isinstance(novos_itens, list) or len(novos_itens) == 0:
        return error_response(400, "novosItens is required and must be a non-empty array")
    detail = json.dumps({"pedidoId": order_id, "novosItens": novos_itens})
    try:
        response = eventbridge.put_events(
            Entries=[{
                "Source": "app.orders.operations",
                "DetailType": "OrderUpdated",
                "Detail": detail,
                "EventBusName": os.environ["EVENT_BUS_NAME"],
            }]
        )
    except Exception as e:
        print(f"EventBridge error on update: {str(e)}")
        return error_response(500, "Failed to publish update event")
    if response.get("FailedEntryCount", 0) > 0:
        print(f"Failed to publish update event: {response}")
        return error_response(500, "Failed to publish update event")
    return api_response(202, {"status": "Update requested", "orderId": order_id})


def lambda_handler(event, context):
    resource = event.get("resource", "")
    method = event.get("httpMethod", "")
    if resource == "/orders" and method == "GET":
        return list_handler(event, context)
    if resource == "/orders/{orderId}" and method == "GET":
        return get_handler(event, context)
    if resource == "/orders/{orderId}/cancel" and method == "POST":
        return cancel_handler(event, context)
    if resource == "/orders/{orderId}" and method == "PATCH":
        return update_handler(event, context)
    return error_response(404, "Not found")
