import json
import os
import boto3
from datetime import datetime

# Configuração via variáveis de ambiente
DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
table = boto3.resource('dynamodb').Table(DYNAMODB_TABLE)

def lambda_handler(event, context):
    print(f"Processing event from queue: {json.dumps(event)}")
    
    for record in event['Records']:
        try:
            # O EventBridge entrega o evento dentro do 'body' do SQS
            envelope = json.loads(record['body'])
            order_data = envelope['detail']
            
            order_id = order_data.get('pedidoId')
            
            # Objeto final para persistência
            processed_item = {
                'orderId': str(order_id),
                'clientId': str(order_data.get('clienteId')),
                'items': order_data.get('itens', []),
                'origin': order_data.get('origem', 'API'),
                'status': 'PROCESSED',
                'processedAt': datetime.utcnow().isoformat() + "Z",
                'eventTime': envelope.get('time')
            }
            
            # Limpeza de campos nulos para o DynamoDB
            item_final = {k: v for k, v in processed_item.items() if v is not None}
            
            table.put_item(Item=item_final)
            print(f"Order {order_id} successfully persisted in production database.")
            
        except Exception as e:
            print(f"Error processing record: {str(e)}")
            raise e
            
    return {'statusCode': 200}