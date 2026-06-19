import os
import boto3
from datetime import datetime
from botocore.exceptions import ClientError
from common.sqs import parse_detail
from common.sns import publish_error

SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
sns_client = boto3.client('sns')
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
    batch_item_failures = []
    for record in event["Records"]:
        try:
            payload = parse_detail(record)
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
                if SNS_TOPIC_ARN:
                    publish_error(sns_client, SNS_TOPIC_ARN, f"Order Not Found for {action}", {
                        'orderId': str(order_id),
                        'operation': action,
                        'message': f"Order does not exist, {action} skipped."
                    })
            else:
                print(f"DynamoDB error: {e}")
                batch_item_failures.append({"itemIdentifier": record['messageId']})
        except Exception as e:
            print(f"Error: {e}")
            batch_item_failures.append({"itemIdentifier": record['messageId']})
    return {"batchItemFailures": batch_item_failures}


def cancel_handler(event, context):
    return _handler(event, context, "cancel")


def update_handler(event, context):
    return _handler(event, context, "update")
