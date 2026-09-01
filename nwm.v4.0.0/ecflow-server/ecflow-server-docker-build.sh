#!/bin/bash

set -euo pipefail

## 
## \brief 
## Build a docker image of an ecflow server and optionally run its built-in unit tests via `ctest`.
## 
## \desc
## Has 1 positional argument and 0 named arguments.
## 
## \option RUN_TESTS
## Dictates whether ecFlow server unit tests are ran after building. Choices: [yes, no].
## 


RUN_TESTS=$1

# BOOST_VERS_DOT=1.89.0
# BOOST_VERS_UNDER=1_89_0

BOOST_VERS_DOT=1.91.0
BOOST_VERS_UNDER=1_91_0

echo "Building ecflow server image..."
sudo docker build \
    --build-arg BOOST_VERS_DOT=${BOOST_VERS_DOT} \
    --build-arg BOOST_VERS_UNDER=${BOOST_VERS_UNDER} \
    -t ecflow-server \
    -f Dockerfile.ecflow-server \
    .. 
echo "Done building ecflow server image."

if [ "${RUN_TESTS,,}" = "yes" ]; then
    echo "Running ecflow server's unit tests..."
    sudo docker run -t ecflow-server ctest --test-dir /src/ecflow/build -E '^u_server_authentication$'
    echo "Done with ecflow server tests."
else
    echo "Skipping ecflow server's unit tests."
fi
