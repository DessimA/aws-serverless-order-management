import json, os, boto3
from datetime import datetime
table = boto3.resource('dynamodb').Table(os.environ['DYNAMODB_TABLE'])

def lambda_handler(event, context):
    for record in event['Records']:
        try:
            payload = json.loads(record['body'])['detail']
            order_id = payload.get('pedidoId')
            new_items = payload.get('novosItens')
            if order_id and new_items is not None:
                table.update_item(
                    Key={'orderId': str(order_id)},
                    UpdateExpression="SET #i = :items, #s = :status, updatedAt = :ts",
                    ExpressionAttributeNames={'#i': 'items', '#s': 'status'},
                    ExpressionAttributeValues={
                        ':items': new_items,
                        ':status': 'UPDATED',
                        ':ts': datetime.utcnow().isoformat() + "Z"
                    }
                )
                print(f"Order {order_id} updated with new items")
        except Exception as e:
            print(f"Error: {str(e)}"); raise e
    return {'statusCode': 200}