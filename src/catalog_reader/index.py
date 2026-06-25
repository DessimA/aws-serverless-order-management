import os
import boto3
from botocore.exceptions import ClientError
from common.http import api_response, error_response

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])


def lambda_handler(event, context):
    resource = event.get("resource", "")
    if resource == "/catalog":
        return list_handler(event, context)
    if resource == "/catalog/{cursoId}":
        return get_handler(event, context)
    return error_response(404, "Not found")


def list_handler(event, context):
    try:
        items = []
        kwargs = {
            "FilterExpression": "disponivel = :v",
            "ExpressionAttributeValues": {":v": True},
        }
        while True:
            result = table.scan(**kwargs)
            items.extend(result.get("Items", []))
            last_key = result.get("LastEvaluatedKey")
            if not last_key:
                break
            kwargs["ExclusiveStartKey"] = last_key
        return api_response(200, {"items": items, "count": len(items)})
    except ClientError as e:
        print(f"DynamoDB ClientError scanning catalog: {e}")
        return error_response(500, "Internal server error")
    except Exception as e:
        print(f"Unexpected error: {e}")
        return error_response(500, "Internal server error")


def get_handler(event, context):
    try:
        params = event.get("pathParameters") or {}
        curso_id = params.get("cursoId")
        if not curso_id:
            return error_response(400, "Missing cursoId")

        result = table.get_item(Key={"cursoId": str(curso_id)})
        if "Item" not in result:
            return error_response(404, "Course not found")

        item = result["Item"]
        if not item.get("disponivel", True):
            return error_response(404, "Course not found")

        return api_response(200, item)

    except ClientError as e:
        print(f"DynamoDB ClientError getting curso: {e}")
        return error_response(500, "Internal server error")
    except Exception as e:
        print(f"Unexpected error: {e}")
        return error_response(500, "Internal server error")
