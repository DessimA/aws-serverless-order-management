import json
import os
import boto3
from botocore.exceptions import ClientError
from common.http import api_response, error_response

table = boto3.resource("dynamodb").Table(os.environ["DYNAMODB_TABLE"])


def lambda_handler(event, context):
    try:
        params = event.get("pathParameters") or {}
        order_id = params.get("orderId")
        if not order_id:
            return error_response(400, "Missing orderId")

        result = table.get_item(Key={"orderId": str(order_id)})
        if "Item" not in result:
            return error_response(404, "Order not found")

        return api_response(200, result["Item"])

    except ClientError as e:
        print(f"DynamoDB ClientError reading order: {e}")
        return error_response(500, "Internal server error")
    except Exception as e:
        print(f"Unexpected error: {e}")
        return error_response(500, "Internal server error")
