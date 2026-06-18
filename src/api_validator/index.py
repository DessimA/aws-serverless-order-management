import json
import os
import boto3
from datetime import datetime

# Inicializacao do cliente EventBridge
events = boto3.client('events')

# Variaveis de ambiente configuradas no deploy
EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']

def lambda_handler(event, context):
    print(f"Ingestion request received: {json.dumps(event)}")

    try:
        # Extração e parse do corpo da requisição
        body_str = event.get('body', '{}')
        body = json.loads(body_str) if body_str else {}

        order_id = body.get('pedidoId')
        client_id = body.get('clienteId')

        # Validacao de campos obrigatorios
        if not order_id or not client_id:
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json'},
                'body': json.dumps({'error': 'pedidoId and clienteId are required'})
            }

        # Preparacao do evento para o EventBridge
        # Nota: Source e DetailType devem coincidir com a regra de roteamento
        event_detail = {
            'pedidoId': str(order_id),
            'clienteId': str(client_id),
            'itens': body.get('itens', []),
            'origem': 'API',
            'timestamp': datetime.utcnow().isoformat() + "Z"
        }

        response = events.put_events(
            Entries=[
                {
                    'Source': 'lab.aula1.pedidos.validacao',
                    'DetailType': 'NovoPedidoValidado',
                    'Detail': json.dumps(event_detail),
                    'EventBusName': EVENT_BUS_NAME
                }
            ]
        )

        # Verificacao de falha na publicacao do evento
        if response['FailedEntryCount'] > 0:
            print(f"Error publishing to EventBridge: {response}")
            raise Exception("Failed to publish event to EventBridge")

        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'status': 'Order accepted',
                'eventId': response['Entries'][0].get('EventId')
            })
        }

    except json.JSONDecodeError:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'Invalid JSON format'})
        }
    except Exception as e:
        print(f"Critical error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Internal server error during ingestion'})
        }