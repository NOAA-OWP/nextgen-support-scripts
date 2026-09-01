# Login the testbed cluster and start a desktop

`https://cloud.nextgenwaterprediction.com/clusters/Zhengtao.Cui/opertestbed`

# Clone `nwm-automation-scripts`

Open a terminal and clone the `development` branch.

  `git clone -b development https://github.com/NGWPC/nwm-automation-scripts.git`

# Install ecFlow Server

## (Docker) Container for ecFlow Server

See notes in [ecflow-server/README.md](ecflow-server/README.md) for details.

```bash
# Build. Optionally run ecFlow server unit (choose yes or no).
RUN_ECFLOW_SERVER_TESTS=no
( cd ecflow-server && ./ecflow-server-docker-build.sh ${RUN_ECFLOW_SERVER_TESTS} )
# Start.
docker stop ecflow-server 2>/dev/null || true
docker run --rm -d --name ecflow-server -p 3141:3141 -v "$(pwd)/ecflow-server/data/ecflow:/data/ecflow" ecflow-server /usr/local/ecflow/bin/ecflow_server
# Ping.
ecflow_client --ping
```

## Alternative ecFlow Server Installation

TODO (e.g. apt install)

# Run the testbed installation script

```
cd nwm-automation-scripts/nwm.v4.0.0
./install_testbed.sh
```
This will start a EcFlow server on the default port (3141) (unless it is already running) and install the EcFlow/NCO scripts for NWM.  The script also accept a port number as an argument. You can choose an unused port number if the default port number has already been used, 

```
cd nwm-automation-scripts/nwm.v4.0.0
./install_testbed.sh 3500
```

# Start EcFlow UI

```
/contrib/software/ecflow/5.6.0/bin/ecflow_ui &

```

# Connect to EcFlow server

1. From the menu, select "Servers" -> "Manage Servers ...", then "Add Server". 
2. Name anything you want for the server name, such as 'testserver'.
3. Hostname is 'localhost'.
4. Port is '3141' or the port number you selected during installation.
