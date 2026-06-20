# Contributing

Thanks for your interest in contributing to this project.

## How to Contribute

- **Issues**: Open an issue for bugs, improvements, or questions.
- **Pull Requests**: Fork the repo, create a branch, and submit a PR. Keep changes focused.

## Getting Started

1.  Clone the repo.
2.  Copy `.env.example` to `.env` and fill in the variables.
3.  Start LocalStack: `docker compose up -d`
4.  Run the full pipeline: `./run.sh`
5.  Run individual validations: `./scripts/validate-flow.sh`

## Project Structure

```
├── scripts/        # IaC via AWS CLI shell scripts (deploy, cleanup, validate)
├── src/            # Lambda functions (Python 3.12, one directory per function)
├── frontend/       # S3 static website dashboard (HTML, CSS, JS)
├── samples/        # Example payload files
└── .env.example    # Environment variable template
```

## Code Standards

### Shell Scripts
- Use `set -euo pipefail` at the top.
- Source `lib.sh` for shared helpers.
- Every resource must be idempotent (check existence before creating).
- Validate every resource after creation (use functions from `lib.sh`).

### Python
- Python 3.12 + boto3.
- Lambda handlers receive `event` and `context`.
- Use `json.loads(event['body'])` for API Gateway payloads.
- Use `common.sqs.parse_body()` and `common.sqs.parse_detail()` for SQS/EventBridge payloads instead of direct `json.loads(event['detail'])`, because EventBridge may deliver `detail` as a native dict (see docs/common.md).

### Commits
- Use conventional prefixes: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`.
- Write in English.
- Keep messages short and descriptive.

## Testing

- `./scripts/validate-flow.sh` runs a full E2E test after deployment.
- The frontend dashboard (S3 website) provides manual testing for all flows.
- Check DynamoDB tables and SQS queues via AWS CLI after tests.
