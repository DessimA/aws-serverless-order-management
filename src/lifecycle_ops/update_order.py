import json, os, boto3
from datetime import datetime
from botocore.exceptions import ClientError
production_table = boto3.resource('dynamodb').Table(os.environ['DYNAMODB_TABLE'])

def lambda_handler(event, context):
    for record in event['Records']:
        try:
            payload = json.loads(json.loads(record['body']).get('detail', '{}'))
            order_id = payload.get('pedidoId')
            new_items = payload.get('novosItens')
            if order_id and new_items is not None and len(new_items) > 0:
                production_table.update_item(
                    Key={'orderId': str(order_id)},
                    UpdateExpression="SET #i = :items, #s = :status, updatedAt = :ts",
                    ExpressionAttributeNames={'#i': 'items', '#s': 'status'},
                    ExpressionAttributeValues={
                        ':items': new_items,
                        ':status': 'UPDATED',
                        ':ts': datetime.utcnow().isoformat() + "Z"
                    },
                    ConditionExpression='attribute_exists(orderId)'
                )
                print(f"Order {order_id} updated with new items")
            else:
                print(f"Skipping record with missing or empty data for order {order_id}")
        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                print(f"Order not found for update, skipping.")
            else:
                print(f"DynamoDB error: {str(e)}")
                raise
        except Exception as e:
            print(f"Error: {str(e)}")
            raise
    return {'statusCode': 200}
