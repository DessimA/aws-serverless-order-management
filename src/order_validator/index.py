import json
import os
import boto3
from common.sns import publish_error
from common.utils import utcnow_iso, log_event

eventbridge_client = boto3.client('events')
sns_client = boto3.client('sns')

EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']

def lambda_handler(event, context):
    record_count = len(event.get('Records', []))
    print(f"Validation processing {record_count} records")
    batch_item_failures = []

    for record in event['Records']:
        try:
            body = json.loads(record['body'])

            order_id = body.get('pedidoId')
            client_id = body.get('clienteId')

            if not order_id or not client_id:
                log_event("order_validator", order_id, "Skipping record with missing pedidoId or clienteId")
                publish_error(sns_client, SNS_TOPIC_ARN, "Order Validation Malformed Record", {
                    'error': "Skipping record with missing pedidoId or clienteId",
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

            log_event("order_validator", order_id, "Order validated and published to EventBridge")

        except Exception as e:
            print(f"Error processing order: {str(e)}")
            publish_error(sns_client, SNS_TOPIC_ARN, "Order Validation Error", {
                'error': str(e),
                'body': record.get('body', 'N/A')
            })
            batch_item_failures.append({"itemIdentifier": record['messageId']})

    return {"batchItemFailures": batch_item_failures}
