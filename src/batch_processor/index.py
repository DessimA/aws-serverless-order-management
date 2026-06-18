import json
import os
import boto3
from datetime import datetime
import urllib.parse
import uuid

# Inicializacao de clientes
s3 = boto3.client('s3')
events = boto3.client('events')
dynamodb = boto3.resource('dynamodb').Table(os.environ['DYNAMODB_TABLE'])
sns = boto3.client('sns')

EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']

def lambda_handler(event, context):
    print(f"Batch processing started: {json.dumps(event)}")
    
    for record in event['Records']:
        s3_msg = json.loads(record['body'])
        if 'Records' not in s3_msg and 'Message' in s3_msg:
            s3_msg = json.loads(s3_msg['Message'])

        for s3_rec in s3_msg.get('Records', []):
            bucket = s3_rec['s3']['bucket']['name']
            key = urllib.parse.unquote_plus(s3_rec['s3']['object']['key'])
            
            status, details = "PROCESSED", None
            try:
                obj = s3.get_object(Bucket=bucket, Key=key)
                data = json.loads(obj['Body'].read().decode('utf-8'))
                
                if 'lista_pedidos' not in data:
                    raise ValueError("Invalid Schema: 'lista_pedidos' key missing")
                
                for p in data['lista_pedidos']:
                    # Normaliza e publica no EventBridge
                    order_payload = {
                        'pedidoId': str(p.get('id_pedido_arquivo')),
                        'clienteId': str(p.get('id_cliente_arquivo')),
                        'itens': p.get('itens_pedido_arquivo', []),
                        'origem': 'S3_BATCH',
                        'nomeArquivoOriginal': key,
                        'timestamp': datetime.utcnow().isoformat() + "Z"
                    }
                    
                    events.put_events(
                        Entries=[{
                            'Source': 'lab.aula1.pedidos.validacao',
                            'DetailType': 'NovoPedidoValidado',
                            'Detail': json.dumps(order_payload),
                            'EventBusName': EVENT_BUS_NAME
                        }]
                    )
                print(f"File {key} processed and events published to EventBridge.")

            except Exception as e:
                status, details = "ERROR", str(e)
                print(f"Error processing file {key}: {details}")
                sns.publish(
                    TopicArn=os.environ['SNS_TOPIC_ARN'],
                    Subject=f"Batch Error: {key}",
                    Message=details
                )
            
            # Auditoria no DynamoDB
            dynamodb.put_item(Item={
                'file_name': key,
                'status': status,
                'timestamp': datetime.utcnow().isoformat() + "Z",
                'details': details
            })
            
    return {'statusCode': 200}