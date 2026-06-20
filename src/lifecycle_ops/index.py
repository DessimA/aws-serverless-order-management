import os
import boto3
from decimal import Decimal
from botocore.exceptions import ClientError
from common.sqs import parse_detail
from common.sns import publish_error
from common.utils import utcnow_iso

SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
sns_client = boto3.client('sns')
production_table = boto3.resource("dynamodb").Table(os.environ["DYNAMODB_TABLE"])


def _to_decimal(obj):
    if isinstance(obj, float):
        return Decimal(str(obj))
    if isinstance(obj, dict):
        return {k: _to_decimal(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_to_decimal(v) for v in obj]
    return obj


def _process(order_id, update_expression, expression_values, expression_attribute_names=None, extra_condition=""):
    if not order_id:
        print("Skipping record with missing pedidoId")
        return
    names = {"#s": "status"}
    if expression_attribute_names:
        names.update(expression_attribute_names)
    condition = "attribute_exists(orderId)"
    if extra_condition:
        condition += f" AND {extra_condition}"
    production_table.update_item(
        Key={"orderId": str(order_id)},
        UpdateExpression=update_expression,
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=expression_values,
        ConditionExpression=condition,
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
                            ":ts": utcnow_iso(),
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
                            ":items": _to_decimal(new_items),
                            ":status": "UPDATED",
                            ":ts": utcnow_iso(),
                            ":cancelledStatus": "CANCELLED",
                        },
                        expression_attribute_names={"#i": "items"},
                        extra_condition="#s <> :cancelledStatus",
                    )
                    print(f"Order {order_id} updated with new items")
                else:
                    print(f"Skipping record with missing or empty data for order {order_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                if operation == "cancel":
                    action = "cancellation"
                    msg = "Order does not exist, cancellation skipped."
                else:
                    action = "update"
                    msg = "Order does not exist or is already cancelled, update skipped."
                print(f"Condition failed for {action}, skipping.")
                if SNS_TOPIC_ARN:
                    publish_error(sns_client, SNS_TOPIC_ARN, f"Order Not Found for {action}", {
                        'orderId': str(order_id),
                        'operation': action,
                        'message': msg
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
