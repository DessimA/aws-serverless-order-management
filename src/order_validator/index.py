import json
import os
import boto3
from datetime import datetime

eventbridge_client = boto3.client('events')
sns_client = boto3.client('sns')

EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']

def lambda_handler(event, context):
    print(f"Validation processing: {json.dumps(event)}")

    for record in event['Records']:
        try:
            body = json.loads(record['body'])

            order_id = body.get('pedidoId')
            client_id = body.get('clienteId')

            if not order_id or not client_id:
                print(f"Skipping record with missing pedidoId or clienteId")
                continue

            event_detail = {
                'pedidoId': str(order_id),
                'clienteId': str(client_id),
                'itens': body.get('itens', []),
                'origem': 'API',
                'timestamp': datetime.utcnow().isoformat() + "Z"
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
            try:
                sns_client.publish(
                    TopicArn=SNS_TOPIC_ARN,
                    Subject="Order Validation Error",
                    Message=json.dumps({
                        'error': str(e),
                        'body': record.get('body', 'N/A')
                    })
                )
            except Exception as sns_err:
                print(f"Failed to publish SNS alert: {sns_err}")

    return {'statusCode': 200}
