# Security Policy

## Supported Versions

Only the latest commit on the `main` branch is supported. There are no tagged releases.

## Reporting a Vulnerability

If you discover a security vulnerability, please open a GitHub Issue with the label `security` or contact the maintainer directly at j.anderson.mect@gmail.com.

Do not open a public issue for critical vulnerabilities.

## Scope

This project is a learning/demonstration system. Security considerations:

- The AWS infrastructure is provisioned with least-privilege IAM policies.
- API Gateway endpoints default to `authorization-type: NONE` for testing purposes.
- The main frontend (index.html) is a portfolio product intended for end-user access, demonstrating the full order lifecycle.
- The QA Dashboard (qa.html) is an internal testing tool that requires an API Key (x-api-key header) for write operations. It should not be promoted to end users.
- SNS email notifications are used for error alerts only.
- No secrets or credentials are committed to the repository.

## Response

Vulnerability reports will be acknowledged within 48 hours. A fix will be provided within 7 days depending on severity.
