#!/bin/bash
#
# Start an ecflow server container.
#
# Optional mode:
#   test-only  Start server, run client tests, then stop server and exit.
#
# Default:
#   Start server and exit, leaving the server running.
#

set -euo pipefail

NETWORK="ecflow-net"
MODE="${1:-start}"

if [[ "${MODE}" != "start" && "${MODE}" != "test-only" ]]; then
	echo "Usage: $0 [test-only]"
	exit 2
fi

mkdir -p "${DATAROOT}"

echo "DATAROOT=${DATAROOT}"

# idempotent network creation
echo "Creating network..."
docker network inspect "${NETWORK}" >/dev/null 2>&1 || docker network create "${NETWORK}"

echo "Stopping container if it already exists..."
docker stop ecflow-server 2>/dev/null || true

# Clean up ecflow data directory to ensure fresh start (removes checkpoint with HALTED state)
# The /data/ecflow inside the container is mounted from the host
echo "Cleaning ecflow data directory..."
rm -rf "${DATAROOT}"/ecflow/* 2>/dev/null || true
rm -rf "${DBNROOT}"/user/usgs_api/* 2>/dev/null || true

# Start server container.
# Mount paths at their host-absolute locations so that docker_run calls
# (which go through the host Docker daemon via the socket) use correct -v paths.
echo "Starting server container..."
mkdir -p ${DBNROOT}/ecflow/log
docker run --rm -d --net "${NETWORK}" --name ecflow-server \
  -e ECF_LOG=${DBNROOT}/ecflow/log/ecf_server.log  \
  -e ECF_TIMEOUT=600  \
  -e ECF_PORT=${ECF_PORT}  \
  -p ${ECF_PORT}:${ECF_PORT} \
  -v "/var/run/docker.sock:/var/run/docker.sock" \
  -v "${COMROOT}:${COMROOT}"           \
  -v "${DBNROOT}:${DBNROOT}"           \
  -v "${DCOMROOT}:${DCOMROOT}"           \
  -v "${NWM_PACKAGE_DIR}:${NWM_PACKAGE_DIR}" \
  -v "${DATAROOT}:${DATAROOT}" \
  ecflow-server ecflow_server
echo "Container started."

if [[ "${MODE}" == "test-only" ]]; then
	echo "Pinging server container from another container..."
	docker run --rm --net "${NETWORK}" --name ecflow-client ecflow-server ecflow_client --host=ecflow-server --ping
	echo "Successful ping to server from another container."

	echo "Ping from local client..."
	ecflow_client --host=localhost --port 3141 --ping
	echo "Succeeded ping from local client."

	echo "Stopping server container..."
	docker stop ecflow-server 2>/dev/null || true
	echo "Stopped server container."
else
	echo "Server is running (default mode)."
fi

set -x
exit 0
