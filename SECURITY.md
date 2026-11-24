# Security policy

## Reporting a security issue

Do not open a public GitHub issue for credentials, authentication weaknesses, secret exposure, or other security-sensitive findings.

If GitHub private vulnerability reporting is enabled for this repository, use that channel. Otherwise, contact the repository owner privately through GitHub before disclosing details publicly.

## Do not commit secrets

Never commit:

* Prism Central passwords or API tokens.
* `.env` files containing credentials.
* Private keys, client certificates, or credential caches.
* Raw API responses from customer or production environments.
* Output directories containing infrastructure metadata.

The script intentionally reads the password through a hidden prompt and does not support a password command-line argument.

## Scope

This project performs read-only Prism Central API calls, but those calls can still create API load. Test changes against a controlled environment and use the minimum required permissions.
