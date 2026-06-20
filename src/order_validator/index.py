import json
import os
import boto3
from common.sns import publish_error
from common.utils import utcnow_iso

eventbridge_client = boto3.client('events')
sns_client = boto3.client('sns')

EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']

def lambda_handler(event, context):
    print(f"Validation processing: {json.dumps(event)}")
    batch_item_failures = []

    for record in event['Records']:
        try:
            body = json.loads(record['body'])

            order_id = body.get('pedidoId')
            client_id = body.get('clienteId')

            if not order_id or not client_id:
                error_msg = "Skipping record with missing pedidoId or clienteId"
                print(error_msg)
                publish_error(sns_client, SNS_TOPIC_ARN, "Order Validation Malformed Record", {
                    'error': error_msg,
                    'body': record.get('body', 'N/A')
                })
                continue

            event_detail = {
                'pedidoId': str(order_id),
                'clienteId': str(client_id),
                'itens': body.get('itens', []),
                'origem': 'API',
                'timestamp': utcnow_iso()
            }

            response = eventbridge_client.put_events(
                Entries=[{
                    'Source': 'app.orders.validation',
                    'DetailType': 'OrderValidated',
                    'Detail': json.dumps(event_detail),
                    'EventBusName': EVENT_BUS_NAME
                }]
            )

            if response['FailedEntryCount'] > 0:
                raise Exception(f"EventBridge put_events failed: {response}")

            print(f"Order {order_id} validated and published to EventBridge")

        except Exception as e:
            print(f"Error processing order: {str(e)}")
            publish_error(sns_client, SNS_TOPIC_ARN, "Order Validation Error", {
                'error': str(e),
                'body': record.get('body', 'N/A')
            })
            batch_item_failures.append({"itemIdentifier": record['messageId']})

    return {"batchItemFailures": batch_item_failures}
