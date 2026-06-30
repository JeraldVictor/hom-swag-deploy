#!/bin/sh
set -eu

set -- /portainer "$@"

if [ -n "${PORTAINER_ADMIN_PASSWORD_FILE:-}" ] && [ -f "$PORTAINER_ADMIN_PASSWORD_FILE" ]; then
  set -- "$@" --admin-password-file "$PORTAINER_ADMIN_PASSWORD_FILE"
elif [ -n "${PORTAINER_ADMIN_PASSWORD_FILE:-}" ]; then
  echo "Portainer password file not found: ${PORTAINER_ADMIN_PASSWORD_FILE}"
  echo "If using a host file, mount it to /run/secrets and set PORTAINER_ADMIN_PASSWORD_FILE accordingly."
fi

if [ -n "${PORTAINER_ADMIN_PASSWORD_HASH:-}" ] && [ -z "${PORTAINER_ADMIN_PASSWORD_FILE:-}" ]; then
  set -- "$@" --admin-password "$PORTAINER_ADMIN_PASSWORD_HASH"
fi

exec "$@"
