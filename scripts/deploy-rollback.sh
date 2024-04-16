#!/bin/bash
set -euo pipefail

BLUE_SERVICE="blue-web"
GREEN_SERVICE="green-web"
SERVICE_PORT=3000
TIMEOUT=60 # seconds
SLEEP_INTERVAL=5 # time to sleep between retries in seconds
MAX_RETRIES=$((TIMEOUT / SLEEP_INTERVAL))
TRAEFIK_NETWORK="blue_green_deploy"
TRAEFIK_API_URL="http://localhost:8080/api/http/services"

# Find the current active service
if docker ps --format '{{.Names}}' | grep -q "${BLUE_SERVICE}"; then
  ACTIVE_SERVICE="${BLUE_SERVICE}"
  INACTIVE_SERVICE="${GREEN_SERVICE}"
elif docker ps --format '{{.Names}}' | grep -q "${GREEN_SERVICE}"; then
  ACTIVE_SERVICE="${GREEN_SERVICE}"
  INACTIVE_SERVICE="${BLUE_SERVICE}"
else
  ACTIVE_SERVICE=""
fi

if [[ -z "${ACTIVE_SERVICE}" ]]; then
  echo "No active service found"
  exit 1
fi

echo "Starting rollback from ${INACTIVE_SERVICE} to ${ACTIVE_SERVICE}..."
docker compose start ${INACTIVE_SERVICE}

# Wait for the new service to be up.
echo "Waiting for ${INACTIVE_SERVICE} to become healthy..."
for ((i=1; i<=$MAX_RETRIES; i++)); do
  CONTAINER_IP=$(docker inspect --format='{{range $key, $value := .NetworkSettings.Networks}}{{if eq $key "'"${TRAEFIK_NETWORK}"'"}}{{$value.IPAddress}}{{end}}{{end}}' "${INACTIVE_SERVICE}" || true)
  if [[ -z "${CONTAINER_IP}" ]]; then
    # The docker inspect command failed, so sleep for a bit and retry.
    sleep "${SLEEP_INTERVAL}"
    continue
  fi

  HEALTH_CHECK_URL="http://${CONTAINER_IP}:${SERVICE_PORT}"
  if curl --fail --silent "${HEALTH_CHECK_URL}" >/dev/null; then
    echo "${INACTIVE_SERVICE} is healthy."
    break
  fi

  sleep "${SLEEP_INTERVAL}"
done

# If the new environment is not healthy within the timeout, stop it and exit with an error.
if ! curl --fail --silent "${HEALTH_CHECK_URL}" >/dev/null; then
  echo "${INACTIVE_SERVICE} did not become healthy within ${TIMEOUT} seconds."
  docker compose stop --timeout=30 ${INACTIVE_SERVICE}
  exit 1
fi

# Check that Traefik recognizes the new container.
echo "Checking if Traefik recognizes ${INACTIVE_SERVICE}..."
for ((i=1; i<=$MAX_RETRIES; i++)); do
  TRAEFIK_SERVER_STATUS=$(curl --fail --silent "${TRAEFIK_API_URL}" | jq --arg container_ip "http://${CONTAINER_IP}:${SERVICE_PORT}" '.[] | select(.type == "loadbalancer") | select(.serverStatus[$container_ip] == "UP") | .serverStatus[$container_ip]')
  if [[ -n "${TRAEFIK_SERVER_STATUS}" ]]; then
    echo "Traefik recognizes ${INACTIVE_SERVICE} as healthy."
    break
  fi

  sleep "${SLEEP_INTERVAL}"
done

# If Traefik does not recognize the new container within the timeout, stop it and exit with an error.
if [[ -z "${TRAEFIK_SERVER_STATUS}" ]]; then
  echo "Traefik did not recognize ${INACTIVE_SERVICE} within ${TIMEOUT} seconds."
  docker compose stop --timeout=30 $INACTIVE_SERVICE
  exit 1
fi

# Set Traefik priority label to 0 on the old service and stop the old environment if it was previously running.
if [[ -n "${ACTIVE_SERVICE}" ]]; then
  echo "Stopping ${ACTIVE_SERVICE} container."
  docker compose stop --timeout=30 $ACTIVE_SERVICE
fi
