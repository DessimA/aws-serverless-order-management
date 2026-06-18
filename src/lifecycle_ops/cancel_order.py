import json, os, boto3
from datetime import datetime
from botocore.exceptions import ClientError
table = boto3.resource('dynamodb').Table(os.environ['DYNAMODB_TABLE'])

def lambda_handler(event, context):
    for record in event['Records']:
        try:
            payload = json.loads(record['body']).get('detail', {})
            order_id = payload.get('pedidoId')
            if order_id:
                table.update_item(
                    Key={'orderId': str(order_id)},
                    UpdateExpression="SET #s = :status, updatedAt = :ts",
                    ExpressionAttributeNames={'#s': 'status'},
                    ExpressionAttributeValues={
                        ':status': 'CANCELLED',
                        ':ts': datetime.utcnow().isoformat() + "Z"
                    },
                    ConditionExpression='attribute_exists(orderId)'
                )
                print(f"Order {order_id} marked as CANCELLED")
            else:
                print("Skipping record with missing pedidoId")
        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                print(f"Order not found for cancellation, skipping.")
            else:
                print(f"DynamoDB error: {str(e)}")
                raise
        except Exception as e:
            print(f"Error: {str(e)}")
            raise
    return {'statusCode': 200}
