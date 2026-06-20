import json
import os
import boto3
from decimal import Decimal
from botocore.exceptions import ClientError
from common.sqs import parse_detail, parse_body
from common.sns import publish_error
from common.utils import utcnow_iso

DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
sns_client = boto3.client('sns')
production_table = boto3.resource('dynamodb').Table(DYNAMODB_TABLE)

def _to_decimal(obj):
    if isinstance(obj, float):
        return Decimal(str(obj))
    if isinstance(obj, dict):
        return {k: _to_decimal(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_to_decimal(v) for v in obj]
    return obj


def lambda_handler(event, context):
    print(f"Processing event from queue: {json.dumps(event)}")
    batch_item_failures = []

    for record in event['Records']:
        try:
            envelope = parse_body(record)
            order_detail = parse_detail(record, envelope=envelope)

            order_id = order_detail.get('pedidoId')
            if not order_id:
                print(f"Skipping record with missing pedidoId")
                continue

            dynamodb_item = {
                'orderId': str(order_id),
                'clientId': str(order_detail.get('clienteId')),
                'items': order_detail.get('itens', []),
                'origin': order_detail.get('origem', 'API'),
                'status': 'PROCESSED',
                'processedAt': utcnow_iso(),
                'eventTime': envelope.get('time')
            }

            clean_item = _to_decimal({k: v for k, v in dynamodb_item.items() if v is not None})

            production_table.put_item(
                Item=clean_item,
                ConditionExpression='attribute_not_exists(orderId)'
            )
            print(f"Order {order_id} successfully persisted in production database.")

        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                print(f"Order {order_id} already exists, skipping duplicate.")
                if SNS_TOPIC_ARN:
                    publish_error(sns_client, SNS_TOPIC_ARN, "Duplicate Order Detected", {
                        'orderId': str(order_id),
                        'message': 'Order already exists in production table, skipped.'
                    })
            else:
                print(f"DynamoDB error processing record: {str(e)}")
                batch_item_failures.append({"itemIdentifier": record['messageId']})
        except Exception as e:
            print(f"Error processing record: {str(e)}")
            batch_item_failures.append({"itemIdentifier": record['messageId']})

    return {"batchItemFailures": batch_item_failures}
