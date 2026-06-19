import json
import os
import boto3
from datetime import datetime
from botocore.exceptions import ClientError

production_table = boto3.resource("dynamodb").Table(os.environ["DYNAMODB_TABLE"])


def _process(order_id, update_expression, expression_values):
    if not order_id:
        print("Skipping record with missing pedidoId")
        return
    production_table.update_item(
        Key={"orderId": str(order_id)},
        UpdateExpression=update_expression,
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues=expression_values,
        ConditionExpression="attribute_exists(orderId)",
    )


def _handler(event, context, operation):
    for record in event["Records"]:
        try:
            payload = json.loads(json.loads(record["body"]).get("detail", "{}"))
            order_id = payload.get("pedidoId")
            if operation == "cancel":
                if order_id:
                    _process(
                        order_id,
                        "SET #s = :status, updatedAt = :ts",
                        {
                            ":status": "CANCELLED",
                            ":ts": datetime.utcnow().isoformat() + "Z",
                        },
                    )
                    print(f"Order {order_id} marked as CANCELLED")
                else:
                    print("Skipping record with missing pedidoId")
            elif operation == "update":
                new_items = payload.get("novosItens")
                if order_id and new_items is not None and len(new_items) > 0:
                    _process(
                        order_id,
                        "SET #i = :items, #s = :status, updatedAt = :ts",
                        {
                            ":items": new_items,
                            ":status": "UPDATED",
                            ":ts": datetime.utcnow().isoformat() + "Z",
                        },
                    )
                    print(f"Order {order_id} updated with new items")
                else:
                    print(f"Skipping record with missing or empty data for order {order_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                action = "cancellation" if operation == "cancel" else "update"
                print(f"Order not found for {action}, skipping.")
            else:
                print(f"DynamoDB error: {e}")
                raise
        except Exception as e:
            print(f"Error: {e}")
            raise
    return {"statusCode": 200}


def cancel_handler(event, context):
    return _handler(event, context, "cancel")


def update_handler(event, context):
    return _handler(event, context, "update")
