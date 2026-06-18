import json
import os
import boto3
from datetime import datetime

eventbridge = boto3.client('events')
s3_client = boto3.client('s3')

EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']
S3_BUCKET = os.environ['S3_BUCKET']

def lambda_handler(event, context):
    headers = {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST,GET,OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type'
    }

    if event.get('httpMethod') == 'OPTIONS':
        return {'statusCode': 200, 'headers': headers, 'body': ''}

    try:
        body = json.loads(event.get('body', '{}'))
        action = body.get('action')

        if not action:
            return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': 'action is required'})}

        if action == 'publish_event':
            return handle_publish_event(body, headers)
        elif action == 'upload_file':
            return handle_upload_file(body, headers)
        elif action == 'list_files':
            return handle_list_files(body, headers)
        else:
            return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': f'Unknown action: {action}'})}

    except json.JSONDecodeError:
        return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': 'Invalid JSON'})}
    except Exception as e:
        return {'statusCode': 500, 'headers': headers, 'body': json.dumps({'error': str(e)})}


def handle_publish_event(body, headers):
    detail_type = body.get('detailType')
    detail = body.get('detail')

    if not detail_type or not detail:
        return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': 'detailType and detail are required'})}

    response = eventbridge.put_events(
        Entries=[{
            'Source': 'app.orders.operations',
            'DetailType': detail_type,
            'Detail': json.dumps(detail),
            'EventBusName': EVENT_BUS_NAME,
            'Time': datetime.utcnow()
        }]
    )

    return {
        'statusCode': 200,
        'headers': headers,
        'body': json.dumps({
            'status': 'Event published',
            'FailedEntryCount': response['FailedEntryCount'],
            'detailType': detail_type,
            'detail': detail,
            'eventBus': EVENT_BUS_NAME
        })
    }


def handle_upload_file(body, headers):
    filename = body.get('filename')
    content = body.get('content')
    content_type = body.get('contentType', 'application/json')

    if not filename or content is None:
        return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': 'filename and content are required'})}

    if isinstance(content, dict) or isinstance(content, list):
        content = json.dumps(content)

    s3_client.put_object(
        Bucket=S3_BUCKET,
        Key=filename,
        Body=content.encode('utf-8') if isinstance(content, str) else content,
        ContentType=content_type
    )

    return {
        'statusCode': 200,
        'headers': headers,
        'body': json.dumps({
            'status': 'File uploaded',
            'bucket': S3_BUCKET,
            'key': filename,
            's3_url': f's3://{S3_BUCKET}/{filename}'
        })
    }


def handle_list_files(body, headers):
    prefix = body.get('prefix', '')

    response = s3_client.list_objects_v2(
        Bucket=S3_BUCKET,
        Prefix=prefix
    )

    files = []
    if 'Contents' in response:
        for obj in response['Contents']:
            files.append({
                'key': obj['Key'],
                'size': obj['Size'],
                'lastModified': obj['LastModified'].isoformat() if hasattr(obj['LastModified'], 'isoformat') else str(obj['LastModified'])
            })

    return {
        'statusCode': 200,
        'headers': headers,
        'body': json.dumps({
            'bucket': S3_BUCKET,
            'files': files,
            'count': len(files)
        })
    }
