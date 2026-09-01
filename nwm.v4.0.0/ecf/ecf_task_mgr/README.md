# ecf_task_mgr

Manages ecflow tasks and subtasks. ecflow tracks status at the Task level only — this package adds a Subtask abstraction using ecflow variables.

## Setup

With cwd as repo root of `nwm-automation-scripts`

### 1. Build the ecflow server (Docker)

```bash
( cd nwm.v4.0.0/ecflow-server && sudo bash ecflow-server-docker-build.sh no )
( cd nwm.v4.0.0/ecflow-server && sudo bash ./ecflow-server-start.sh "test-only" )
```

### 2. Build and install the ecflow Python client

```bash
bash nwm.v4.0.0/ecf/ecf_task_mgr/setup/install_ecflow_python_client.sh
```

### 3. Install Python package ecf_task_mgr

```bash
pip install -e nwm.v4.0.0/ecf/ecf_task_mgr
```

### 4. Start the ecflow server

```bash
( cd nwm.v4.0.0/ecflow-server && ./ecflow-server-start.sh )
```

### 5. Run tests on Python package ecf_task_mgr

```bash
# From the source code dir
( cd nwm.v4.0.0/ecf/ecf_task_mgr && pytest )
# More idiomatic alternative
pytest --pyargs ecf_task_mgr.tests
```
