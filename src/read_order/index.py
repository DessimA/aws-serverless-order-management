import json
import os
import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['DYNAMODB_TABLE'])

def lambda_handler(event, context):
    headers = {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET,OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type'
    }

    if event.get('httpMethod') == 'OPTIONS':
        return {'statusCode': 200, 'headers': headers, 'body': ''}

    try:
        order_id = event.get('pathParameters', {}).get('orderId')
        if not order_id:
            return {'statusCode': 400, 'headers': headers, 'body': json.dumps({'error': 'Missing orderId'})}

        result = table.get_item(Key={'orderId': str(order_id)})
        if 'Item' not in result:
            return {'statusCode': 404, 'headers': headers, 'body': json.dumps({'error': 'Order not found'})}

        return {'statusCode': 200, 'headers': headers, 'body': json.dumps(result['Item'])}

    except ClientError as e:
        return {'statusCode': 500, 'headers': headers, 'body': json.dumps({'error': e.response['Error']['Message']})}
    except Exception as e:
        return {'statusCode': 500, 'headers': headers, 'body': json.dumps({'error': str(e)})}
