#!/bin/sh

printf 'WEB_CONTAINER_START_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >&2
printf 'WEB_CONTAINER_PYTHON=%s\n' "$(python3 --version 2>&1)" >&2

exec "$@"
