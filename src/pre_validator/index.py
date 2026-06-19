import json
import os
import uuid
import boto3
from common.http import error_response, api_response

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
            return error_response(400, 'pedidoId and clienteId are required')

        sqs_client.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageGroupId=str(order_id),
            MessageDeduplicationId=str(uuid.uuid4()),
            MessageBody=json.dumps(body)
        )

        print(f"Order {order_id} queued for validation")

        return api_response(200, {'status': 'Order accepted', 'pedidoId': str(order_id)})

    except json.JSONDecodeError:
        return error_response(400, 'Invalid JSON format')
    except Exception as e:
        print(f"Error: {str(e)}")
        return error_response(500, 'Internal server error')
