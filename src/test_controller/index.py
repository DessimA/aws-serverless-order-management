import json
import os
import boto3
from datetime import datetime
from common.http import api_response, error_response

eventbridge = boto3.client('events')
s3_client = boto3.client('s3')

EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']
S3_BUCKET = os.environ['S3_BUCKET']

def lambda_handler(event, context):
    try:
        body = json.loads(event.get('body', '{}'))
        action = body.get('action')

        if not action:
            return error_response(400, 'action is required')

        if action == 'publish_event':
            return handle_publish_event(body)
        elif action == 'upload_file':
            return handle_upload_file(body)
        elif action == 'list_files':
            return handle_list_files(body)
        else:
            return error_response(400, f'Unknown action: {action}')

    except json.JSONDecodeError:
        return error_response(400, 'Invalid JSON')
    except Exception as e:
        return error_response(500, str(e))


def handle_publish_event(body):
    detail_type = body.get('detailType')
    detail = body.get('detail')

    if not detail_type or detail is None:
        return error_response(400, 'detailType and detail are required')

    response = eventbridge.put_events(
        Entries=[{
            'Source': 'app.orders.operations',
            'DetailType': detail_type,
            'Detail': json.dumps(detail),
            'EventBusName': EVENT_BUS_NAME,
            'Time': datetime.utcnow()
        }]
    )

    return api_response(200, {
        'status': 'Event published',
        'FailedEntryCount': response['FailedEntryCount'],
        'detailType': detail_type,
        'detail': detail,
        'eventBus': EVENT_BUS_NAME
    })


def handle_upload_file(body):
    filename = body.get('filename')
    content = body.get('content')
    content_type = body.get('contentType', 'application/json')

    if not filename or content is None:
        return error_response(400, 'filename and content are required')

    if isinstance(content, dict) or isinstance(content, list):
        content = json.dumps(content)

    s3_client.put_object(
        Bucket=S3_BUCKET,
        Key=filename,
        Body=content.encode('utf-8') if isinstance(content, str) else content,
        ContentType=content_type
    )

    return api_response(200, {
        'status': 'File uploaded',
        'bucket': S3_BUCKET,
        'key': filename,
        's3_url': f's3://{S3_BUCKET}/{filename}'
    })


def handle_list_files(body):
    prefix = body.get('prefix', '')
    max_keys = 1000
    files = []
    continuation_token = None

    while True:
        params = {
            'Bucket': S3_BUCKET,
            'Prefix': prefix,
            'MaxKeys': max_keys,
        }
        if continuation_token:
            params['ContinuationToken'] = continuation_token

        response = s3_client.list_objects_v2(**params)

        if 'Contents' in response:
            for obj in response['Contents']:
                files.append({
                    'key': obj['Key'],
                    'size': obj['Size'],
                    'lastModified': obj['LastModified'].isoformat() if hasattr(obj['LastModified'], 'isoformat') else str(obj['LastModified'])
                })

        if not response.get('IsTruncated'):
            break
        continuation_token = response.get('NextContinuationToken')

    return api_response(200, {
        'bucket': S3_BUCKET,
        'files': files,
        'count': len(files)
    })
