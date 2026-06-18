import json, os, boto3
from datetime import datetime
table = boto3.resource('dynamodb').Table(os.environ['DYNAMODB_TABLE'])

def lambda_handler(event, context):
    for record in event['Records']:
        try:
            payload = json.loads(record['body'])['detail']
            order_id = payload.get('pedidoId')
            if order_id:
                table.update_item(
                    Key={'orderId': str(order_id)},
                    UpdateExpression="SET #s = :status, updatedAt = :ts",
                    ExpressionAttributeNames={'#s': 'status'},
                    ExpressionAttributeValues={
                        ':status': 'CANCELLED',
                        ':ts': datetime.utcnow().isoformat() + "Z"
                    }
                )
                print(f"Order {order_id} marked as CANCELLED")
        except Exception as e:
            print(f"Error: {str(e)}"); raise e
    return {'statusCode': 200}