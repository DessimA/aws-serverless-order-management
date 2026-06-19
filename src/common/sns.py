import json


def publish_error(sns_client, topic_arn, subject, details):
    try:
        sns_client.publish(
            TopicArn=topic_arn,
            Subject=subject,
            Message=json.dumps(details),
        )
    except Exception as e:
        print(f"Failed to publish SNS alert: {e}")
