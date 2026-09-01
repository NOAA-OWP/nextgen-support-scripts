# Introductions
This folder contains the scripts to run performance tests on the operational testbed environment. The test VPU domains used are 03S and 03N. There are three types of performance tests.
1. Run the two VPUs in sequence and in parallel, and record the total wallclock time for each run.
2. Run scalability test by varying number of CPUs using VPU 03S only.

# CPU pinning and interference with realtime jobs
There are 18 CPUs in total on the system. The test runs use CPUs 10 to 17 on the testbed system. Currently the scripts are supposed to be run on a compute node using slurm. However, if it is used to run on the front node, choose a time slot that doesn't conflict with the real-time jobs. The AnA and Short Range jobs run at 30 minutes past the hour at every hour. The Extended AnA runs at 18:30 daily. The AnA and Short Range jobs use CPUs 0 to 7, while the Extended AnA job uses CPUs 10 to 17 which are the same CPU sets used by the performance test runs. To avoid conflicts in CPUs, don't run the performance while Extended AnA job is running if running the test on the front node. The Extended AnA job runs at around 18:30 to 19:40 daily on the front node.

# Installation

The test scripts depends on RTE. Install RTE in the `nwm.v4.0.0/ush` directory if it has not been installed. Assuming the current directory is `nwm.v4.0.0/performance_test
```
cd ../ush/
git clone https://github.com/NGWPC/nwm-rte.git
cd ./nwm-rte/
./setup_clone_repos.sh https
./ngen_rte_build.sh
```

# Run tests 
1. Run the two VPUs in sequence and in parallel,
```
sbatch ./run_performance_test.sh
```
2. Run scalability test,
```
sbatch run_perf_scale_test.sh
```
# Check job status
```
squeue
```
# Check result figures
Two figures will be created, `VPU_sequential_vs_parallel.png` and `VPU_mpi_03S_runtime.png`, in the current working directory.

