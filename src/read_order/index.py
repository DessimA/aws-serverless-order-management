import json
import os
import boto3
from botocore.exceptions import ClientError

table = boto3.resource("dynamodb").Table(os.environ["DYNAMODB_TABLE"])

HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}


def lambda_handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode": 200, "headers": HEADERS, "body": ""}

    try:
        order_id = event.get("pathParameters", {}).get("orderId")
        if not order_id:
            return _res(400, {"error": "Missing orderId"})

        result = table.get_item(Key={"orderId": str(order_id)})
        if "Item" not in result:
            return _res(404, {"error": "Order not found"})

        return _res(200, result["Item"])

    except ClientError:
        return _res(500, {"error": "Internal server error"})
    except Exception as e:
        print(f"Unexpected error: {e}")
        return _res(500, {"error": "Internal server error"})


def _res(status, body):
    return {"statusCode": status, "headers": HEADERS, "body": json.dumps(body)}
