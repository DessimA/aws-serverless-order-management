import json
import os
import boto3

sqs_client = boto3.client('sqs')
SQS_QUEUE_URL = os.environ['SQS_QUEUE_URL']

def lambda_handler(event, context):
    print(f"Pre-validation request: {json.dumps(event)}")

    try:
        raw_body = event.get('body', '{}')
        if isinstance(raw_body, dict):
            body = raw_body
        else:
            body = json.loads(raw_body) if raw_body else {}

        order_id = body.get('pedidoId')
        client_id = body.get('clienteId')

        if not order_id or not client_id:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({'error': 'pedidoId and clienteId are required'})
            }

        sqs_client.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageGroupId=str(order_id),
            MessageDeduplicationId=str(order_id),
            MessageBody=json.dumps(body)
        )

        print(f"Order {order_id} queued for validation")

        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({'status': 'Order accepted', 'pedidoId': str(order_id)})
        }

    except json.JSONDecodeError:
        return {
            'statusCode': 400,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({'error': 'Invalid JSON format'})
        }
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({'error': 'Internal server error'})
        }
