import json
import os
import boto3
import urllib.parse
from common.sns import publish_error
from common.sqs import parse_body
from common.utils import utcnow_iso, utcnow_plus_days_epoch, log_event

s3_client = boto3.client('s3')
audit_table = boto3.resource('dynamodb').Table(os.environ['DYNAMODB_TABLE'])
sns_client = boto3.client('sns')

SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']

def lambda_handler(event, context):
    record_count = len(event.get('Records', []))
    print(f"File validation started: {record_count} records")
    batch_item_failures = []

    for record in event['Records']:
        try:
            notification_message = parse_body(record)

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
                    log_event("batch_processor", None, f"File {key} validated successfully with {order_count} orders")

                except Exception as e:
                    status, details = "ERROR", str(e)
                    log_event("batch_processor", None, f"Error validating file {key}: {details}")
                    publish_error(sns_client, SNS_TOPIC_ARN, f"File Validation Error: {bucket}/{key}", {
                        'file': f"s3://{bucket}/{key}",
                        'error': details
                    })

                audit_table.put_item(Item={
                    'file_name': key,
                    'status': status,
                    'timestamp': utcnow_iso(),
                    'details': details or "OK",
                    'expiresAt': utcnow_plus_days_epoch(90)
                })

        except Exception as e:
            print(f"Error processing SQS record: {e}")
            batch_item_failures.append({"itemIdentifier": record['messageId']})

    return {"batchItemFailures": batch_item_failures}
