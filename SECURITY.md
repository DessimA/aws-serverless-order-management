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
- The frontend dashboard is a testing tool and should not be exposed to production traffic.
- SNS email notifications are used for error alerts only.
- No secrets or credentials are committed to the repository.

## Response

Vulnerability reports will be acknowledged within 48 hours. A fix will be provided within 7 days depending on severity.
