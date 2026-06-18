import json
import os
import boto3
from datetime import datetime
from botocore.exceptions import ClientError

DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
table = boto3.resource('dynamodb').Table(DYNAMODB_TABLE)

def lambda_handler(event, context):
    print(f"Processing event from queue: {json.dumps(event)}")

    for record in event['Records']:
        try:
            envelope = json.loads(record['body'])
            order_data = envelope.get('detail', {})

            order_id = order_data.get('pedidoId')
            if not order_id:
                print(f"Skipping record with missing pedidoId")
                continue

            processed_item = {
                'orderId': str(order_id),
                'clientId': str(order_data.get('clienteId')),
                'items': order_data.get('itens', []),
                'origin': order_data.get('origem', 'API'),
                'status': 'PROCESSED',
                'processedAt': datetime.utcnow().isoformat() + "Z",
                'eventTime': envelope.get('time')
            }

            item_final = {k: v for k, v in processed_item.items() if v is not None}

            table.put_item(
                Item=item_final,
                ConditionExpression='attribute_not_exists(orderId)'
            )
            print(f"Order {order_id} successfully persisted in production database.")

        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                print(f"Order {order_id} already exists, skipping duplicate.")
            else:
                print(f"DynamoDB error processing record: {str(e)}")
                raise
        except Exception as e:
            print(f"Error processing record: {str(e)}")
            raise

    return {'statusCode': 200}
