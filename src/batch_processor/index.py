import json
import os
import boto3
from datetime import datetime
import urllib.parse
from common.sns import publish_error

s3_client = boto3.client('s3')
audit_table = boto3.resource('dynamodb').Table(os.environ['DYNAMODB_TABLE'])
sns_client = boto3.client('sns')

SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']

def lambda_handler(event, context):
    print(f"File validation started: {json.dumps(event)}")

    for record in event['Records']:
        notification_message = json.loads(record['body'])
        if 'Records' not in notification_message and 'Message' in notification_message:
            notification_message = json.loads(notification_message['Message'])

        for s3_event_record in notification_message.get('Records', []):
            bucket = s3_event_record['s3']['bucket']['name']
            key = urllib.parse.unquote_plus(s3_event_record['s3']['object']['key'])

            status, details = "PROCESSED", None

            try:
                obj = s3_client.get_object(Bucket=bucket, Key=key)
                data = json.loads(obj['Body'].read().decode('utf-8'))

                if 'lista_pedidos' not in data:
                    raise ValueError("Invalid Schema: 'lista_pedidos' key missing")

                order_count = len(data['lista_pedidos'])
                print(f"File {key} validated successfully with {order_count} orders")

            except Exception as e:
                status, details = "ERROR", str(e)
                print(f"Error validating file {key}: {details}")
                publish_error(sns_client, SNS_TOPIC_ARN, f"File Validation Error: {bucket}/{key}", {
                    'file': f"s3://{bucket}/{key}",
                    'error': details
                })

            audit_table.put_item(Item={
                'file_name': key,
                'status': status,
                'timestamp': datetime.utcnow().isoformat() + "Z",
                'details': details or "OK"
            })

    return {'statusCode': 200}
