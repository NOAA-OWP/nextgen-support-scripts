#!/bin/bash

#SBATCH -J Perf_2_vpus 
#SBATCH -o Perf_2_vpus_%j.log
#SBATCH -t 02:00:00
#SBATCH --nodes 1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=18

function run_vpu()
{
  local is_parallel=$1
  local VPU=$2
  local NPROCS=$3
  local TEST_FORM_ASSIGN_VPU="${INSTALLED_REGIONALIZATION_RESULTS}/vpu_${VPU}/formulation_assignment.csv"
  local TEST_CAT_GRP_VPU="${INSTALLED_REGIONALIZATION_RESULTS}/vpu_${VPU}/catchment_groups.csv"

  if [[ ${is_parallel} == "YES" ]]; then
     echo "Parallel execution of VPU 03S and 03N ... " 
     source my_run.sh && docker_run python -um "ngen_rte.run_regionalization_standalone" \
	     -n ${NPROCS} -fconfig "short_range" -dt "2026-03-30 06:00:00" \
	     -rname "default_short" -nwmout  --vpu ${VPU} \
       	-faf "${TEST_FORM_ASSIGN_VPU}" \
       	-cgf  "${TEST_CAT_GRP_VPU}" --output_format NetCDF --checkpoint_interval 1 & 
  else
     echo "Sequential execution of VPU 03S and 03N ... " 
     source my_run.sh && docker_run python -um "ngen_rte.run_regionalization_standalone" \
	     -n ${nprocs} -fconfig "short_range" -dt "2026-03-30 06:00:00" \
	     -rname "default_short" -nwmout  --vpu ${VPU} \
       	-faf "${TEST_FORM_ASSIGN_VPU}" \
       	-cgf  "${TEST_CAT_GRP_VPU}" --output_format NetCDF --checkpoint_interval 1
  fi
}

set -euo pipefail

now_time=$(date +%s)
ext_ana_time1=$(date -d "17:50" +%s)
ext_ana_time2=$(date -d "19:10" +%s)

sudo systemctl start docker 

workdir=$(pwd)
cd ../ush/nwm-rte
./ngen_rte_build.sh

#
# Extended AnA starts at 18:30z. It'll use the same CPU set as this test. 
# To avoid CPU overloading, don't run test around this time. 
#
#if [ "$now_time" -ge "$ext_ana_time1" ] && [ "$now_time" -le "$ext_ana_time2" ]; then
#    echo "Cannot run tests while Extended AnA is running on the testbed. Exiting ... "
#    exit 0
#fi

# use the working directory on local disk
export RUN_NGEN_ROOT__HOST=/media/test/tmp/vpu/${LOGNAME}

cd ${workdir}
#prepare RTE to run
source ../ush/nwm-rte/config.bashrc

#
# Update the run.sh script
#
RTE=$(pwd)/../ush/nwm-rte
sed  -e "s|\$(pwd)/bin_mounted/|$RTE/bin_mounted/|" \
	-e "/^\s\+time sudo docker/a \ \ \ \ \ \$\{CPUSET_CPUS:+--cpuset-cpus=\"\$\{CPUSET_CPUS\}\"\}  \\\\" \
	-e "s|\$(pwd)|$RUN_NGEN_ROOT__HOST|" \
	-e "/source config.bashrc/d" ../ush/nwm-rte/run.sh > my_run.sh

sudo mkdir -p $RUN_NGEN_ROOT__HOST/logs/docker/run
sudo mkdir -p $RUN_NGEN_ROOT__HOST/logs/rte


################################################
#
# Sequential execution of 03S and 03N
#
#
#clean up first
sudo rm -rf ${RUN_NGEN_ROOT__HOST}/regionalization/*

# Record start time
start_time=$(date +%s)

# --- First VPU ---
VPU="03S"
nprocs=2
export CPUSET_CPUS="16,17"

echo "Running VPU 03S short range on processors ${CPUSET_CPUS} ..."
run_vpu "NO" ${VPU} ${nprocs}

# Record intermediate time
mid_time=$(date +%s)

# --- Second VPU ---
VPU="03N"
export CPUSET_CPUS="10,11,12,13,14,15"
nprocs=6

echo "Running VPU 03N short range on processors ${CPUSET_CPUS} ..."
run_vpu "NO" ${VPU} ${nprocs}

# Record end time
end_time=$(date +%s)

# Calculate elapsed times in seconds
time_between=$((mid_time - start_time))
total_time=$((end_time - start_time))

# Convert total time to H:M:S
vpu1_hours=$((time_between / 3600))
vpu1_minutes=$(((time_between % 3600) / 60))
vpu1_seconds=$((time_between % 60))

# Convert total time to H:M:S
vpu2_hours=$(( (total_time - time_between) / 3600))
vpu2_minutes=$((( (total_time - time_between) % 3600) / 60))
vpu2_seconds=$(( (total_time - time_between) % 60))

# Convert total time to H:M:S
hours=$((total_time / 3600))
minutes=$(((total_time % 3600) / 60))
seconds=$((total_time % 60))

# Output results
echo "Time of the first VPU: ${time_between} seconds"
printf "Time of the first VPU - 03S : %02d:%02d:%02d (H:M:S)\n" "$vpu1_hours" "$vpu1_minutes" "$vpu1_seconds"
printf "Time of the second VPU - 03N : %02d:%02d:%02d (H:M:S)\n" "$vpu2_hours" "$vpu2_minutes" "$vpu2_seconds"
printf "Total time of sequential execution from start to end: %02d:%02d:%02d (H:M:S)\n" "$hours" "$minutes" "$seconds"
printf "Check output files at $RUN_NGEN_ROOT__HOST/test/tmp/regionalization/default_short.\n"



################################################
#
# parallel execution of 03S and 03N
#
#
#clean up first
sudo rm -rf ${RUN_NGEN_ROOT__HOST}/regionalization/*

# Record start time
start_time=$(date +%s)

# --- First VPU ---
VPU="03S"
nprocs=2
export CPUSET_CPUS="16,17"

echo "Running VPU 03S short range on processors ${CPUSET_CPUS} ..."
run_vpu "YES" ${VPU} ${nprocs}

# --- Second VPU ---
VPU="03N"
export CPUSET_CPUS="10,11,12,13,14,15"
nprocs=6

echo "Running VPU 03N short range on processors ${CPUSET_CPUS} ..."
run_vpu "YES" ${VPU} ${nprocs}

wait

# Record end time
end_time=$(date +%s)

total_time_parallel=$((end_time - start_time))

# Convert total time to H:M:S
vpu2_hours=$(( (total_time_parallel - time_between) / 3600))
vpu2_minutes=$((( (total_time_parallel - time_between) % 3600) / 60))
vpu2_seconds=$(( (total_time_parallel - time_between) % 60))

# Convert total time to H:M:S
hours=$((total_time / 3600))
minutes=$(((total_time % 3600) / 60))
seconds=$((total_time % 60))

printf "Total time of parallel execution from start to end: %02d:%02d:%02d (H:M:S)\n" "$hours" "$minutes" "$seconds"

total_minutes=$(( total_time / 60 ))
total_minutes_parallel=$(( total_time_parallel / 60 ))

DATA="Sequential  $total_minutes\nParallel  $total_minutes_parallel\n"

tempdata=$(printf "%b" "$DATA")

  gnuplot -persist <<-EOFMarker
      \$Mydata << EOD
$tempdata
EOD
      # Set terminal to png or pdf for output
      set terminal pngcairo enhanced font 'Arial, 12'
      set output 'VPU_sequential_vs_parallel.png'

      # Set title and labels
      set title "Parallel VPU runs (03S and 03N)"
      set xlabel '2 VPUs - 03S and 03N'
      set ylabel "Wall clock time (mins) " offset 0,0,0
      set key right top
      set yrange [0:*]

      # Set style of bars
      set style data histogram
      set style histogram cluster gap 1
      #set style fill solid
      set style fill pattern border -1

      # Adjust width of bars
      set boxwidth 0.8

      set grid ytics
      # Adjust xtics for labels
      set xtics rotate by -45

      # Plot data from file
      plot \$Mydata using 2:xtic(1) with boxes title 'Wall clock time' fillstyle pattern 2
EOFMarker


exit 0
