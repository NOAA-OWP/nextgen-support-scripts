#!/bin/bash

#SBATCH -J Perf_scale_test 
#SBATCH -o Perf_scale_test_%j.log
#SBATCH -t 02:00:00
#SBATCH --nodes 1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=18

function run_vpu()
{
  local VPU=$1
  local NPROCS=$2
  local TEST_FORM_ASSIGN_VPU="${INSTALLED_REGIONALIZATION_RESULTS}/vpu_${VPU}/formulation_assignment.csv"
  local TEST_CAT_GRP_VPU="${INSTALLED_REGIONALIZATION_RESULTS}/vpu_${VPU}/catchment_groups.csv"

  source my_run.sh && docker_run python -um "ngen_rte.run_regionalization_standalone" \
	     -n ${NPROCS} -fconfig "short_range" -dt "2026-03-30 06:00:00" \
	     -rname "default_short" -nwmout  --vpu ${VPU} \
       	-faf "${TEST_FORM_ASSIGN_VPU}" \
       	-cgf  "${TEST_CAT_GRP_VPU}" --output_format NetCDF --checkpoint_interval 1 
}

function parallel_run_vpu()
{
   local nprocs=$1
   export CPUSET_CPUS="$2"
   local run_time_secs=$3

   #clean up first
   sudo rm -rf ${RUN_NGEN_ROOT__HOST}/regionalization/*

   # Record start time
   local start_time=$(date +%s)

   # --- 1 processor ---
   VPU="03S"

   run_vpu ${VPU} ${nprocs}

   # Record end time
   local end_time=$(date +%s)

   local total_time_secs=$((end_time - start_time))

   # Output results
   eval $run_time_secs="'$total_time_secs'"
}

set -euo pipefail

workdir=$(pwd)

sudo systemctl start docker 

cd ../ush/nwm-rte
./ngen_rte_build.sh

# use the working directory on local disk
export RUN_NGEN_ROOT__HOST=/media/test/tmp/scale/${LOGNAME}

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


DATA="# nprocs  wall clock time (secs)"
################################################
#
# Parallel execution of 03S
#
# 1 processor 

echo "Running VPU 03S short range on processor 0 ..."
parallel_run_vpu 1 "17" total_time
echo "Time of 1 processor: ${total_time} seconds"
# Convert total time to H:M:S
hours=$((total_time / 3600))
minutes=$(((total_time % 3600) / 60))
seconds=$((total_time % 60))
printf "Total time of 1 processor start to end: %02d:%02d:%02d (H:M:S)\n" "$hours" "$minutes" "$seconds"
DATA+=$'\n'"1  $total_time"

# Now save the output files from the serial execution
sudo mv ${RUN_NGEN_ROOT__HOST}/regionalization/default_short/03S/Output \
      ${RUN_NGEN_ROOT__HOST}/Output.serial

echo "------------------------------------------------------------------------------------------"
echo "Archieved the serial run output files to ${RUN_NGEN_ROOT__HOST}/Output.serial."
echo "------------------------------------------------------------------------------------------"

# 2 processors
echo "Running VPU 03S short range on 2 processors ..."

parallel_run_vpu 2 "0,1" total_time
echo "Time of 2 processors: ${total_time} seconds"
# Convert total time to H:M:S
hours=$((total_time / 3600))
minutes=$(((total_time % 3600) / 60))
seconds=$((total_time % 60))
printf "Total time of 2 processors start to end: %02d:%02d:%02d (H:M:S)\n" "$hours" "$minutes" "$seconds"
DATA+=$'\n'"2  $total_time"

# 4 processors
echo "Running VPU 03S short range on 4 processors ..."
parallel_run_vpu 4 "0,1,2,3" total_time
echo "Time of 4 processors: ${total_time} seconds"
# Convert total time to H:M:S
hours=$((total_time / 3600))
minutes=$(((total_time % 3600) / 60))
seconds=$((total_time % 60))
printf "Total time of 4 processors start to end: %02d:%02d:%02d (H:M:S)\n" "$hours" "$minutes" "$seconds"
DATA+=$'\n'"4  $total_time"

# 8 processors
echo "Running VPU 03S short range on 8 processors ..."
parallel_run_vpu 8 "0,1,2,3,4,5,6,7" total_time
echo "Time of 8 processors: ${total_time} seconds"
# Convert total time to H:M:S
hours=$((total_time / 3600))
minutes=$(((total_time % 3600) / 60))
seconds=$((total_time % 60))
printf "Total time of 8 processors start to end: %02d:%02d:%02d (H:M:S)\n" "$hours" "$minutes" "$seconds"
DATA+=$'\n'"8  $total_time"

# 12 processors
echo "Running VPU 03S short range on 12 processors ..."
parallel_run_vpu 12 "0,1,2,3,4,5,6,7,8,9,10,11" total_time
echo "Time of 12 processors: ${total_time} seconds"
# Convert total time to H:M:S
hours=$((total_time / 3600))
minutes=$(((total_time % 3600) / 60))
seconds=$((total_time % 60))
printf "Total time of 12 processors start to end: %02d:%02d:%02d (H:M:S)\n" "$hours" "$minutes" "$seconds"
DATA+=$'\n'"12  $total_time"

# 16 processors
echo "Running VPU 03S short range on 16 processors ..."
parallel_run_vpu 16 "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15" total_time
echo "Time of 16 processors: ${total_time} seconds"
# Convert total time to H:M:S
hours=$((total_time / 3600))
minutes=$(((total_time % 3600) / 60))
seconds=$((total_time % 60))
printf "Total time of 16 processors start to end: %02d:%02d:%02d (H:M:S)\n" "$hours" "$minutes" "$seconds"
DATA+=$'\n'"16  $total_time"

echo "------------------------------------------------------------------------------------------"
echo "Compare the serial run output files to the 16 processor parallel run output files ..."
echo "------------------------------------------------------------------------------------------"
#
# Update the run.sh script
#
RTE=$(pwd)/../ush/nwm-rte
sed  -e "s|\$(pwd)/bin_mounted/|$RTE/bin_mounted/|" \
	-e "/^\s\+time sudo docker/a \ \ \ \ \ \$\{CPUSET_CPUS:+--cpuset-cpus=\"\$\{CPUSET_CPUS\}\"\}  \\\\" \
	-e "/^\s\+time sudo docker/a \ \ \ \ \ -v ${workdir}:${workdir}  \\\\" \
        -e "s|-w \"/ngen-app/bin\"|-w ${workdir}|" \
	-e "s|\$(pwd)|$RUN_NGEN_ROOT__HOST|" \
	-e "/source config.bashrc/d" ../ush/nwm-rte/run.sh > my_run.sh

echo "------------------------------------------------------------------------------------------"
echo "Comparing the catchment_output.nc files ..."
echo " Serial run oututput file is ${RUN_NGEN_ROOT__HOST}/Output.serial/catchment_output.nc."
echo " 16 processor parallel run oututput file is ${RUN_NGEN_ROOT__HOST}/regionalization/default_short/03S/Output/catchment_output.nc."
echo "------------------------------------------------------------------------------------------"

source my_run.sh && docker_run python compare_netcdf.py ./Output/catchment_output.nc \
	/ngwpc/run_ngen/Output.serial/catchment_output.nc

#if [ "$rc" -eq 0 ]; then
#   echo "PASS: The serial run output file is scientifically identical to the parallel run output file!"
#   echo "PASS: The maximum absolute difference is less than 1e-8 and the maximum relative difference is less than 1e-5!"
#else
#   echo "FAIL: The serial run output file is NOT scientifically identical to the parallel run output file!"
#fi

echo "------------------------------------------------------------------------------------------"
echo "Comparing the troute_output_202603300600.nc file ..."
echo " Serial run oututput file is ${RUN_NGEN_ROOT__HOST}/Output.serial/troute_output_202603300600.nc."
echo " 16 processor parallel run oututput file is ${RUN_NGEN_ROOT__HOST}/regionalization/default_short/03S/Output/troute_output_202603300600.nc."
echo "------------------------------------------------------------------------------------------"

source my_run.sh && docker_run python compare_netcdf.py ./Output/troute_output_202603300600.nc \
	/ngwpc/run_ngen/Output.serial/troute_output_202603300600.nc \
	--atol 0.1

#if [ "$rc" -eq 0 ]; then
#   echo "PASS: The serial run output file is scientifically identical to the parallel run output file!"
#   echo "PASS: The maximum absolute difference is less than 5e-2 and the maximum relative difference is less than 1e-5!"
#else
#   echo "FAIL: The serial run output file is NOT scientifically identical to the parallel run output file!"
#fi

echo "------------------------------------------------------------------------------------------"
echo "Comparing the troute_lakeout_202603300600.nc file ..."
echo " Serial run oututput file is ${RUN_NGEN_ROOT__HOST}/Output.serial/troute_lakeout_202603300600.nc."
echo " 16 processor parallel run oututput file is ${RUN_NGEN_ROOT__HOST}/regionalization/default_short/03S/Output/troute_lakeout_202603300600.nc."
echo "------------------------------------------------------------------------------------------"

source my_run.sh && docker_run python compare_netcdf.py ./Output/troute_lakeout_202603300600.nc \
	/ngwpc/run_ngen/Output.serial/troute_lakeout_202603300600.nc \
	--atol 0.001

#if [ "$rc" -eq 0 ]; then
#   echo "PASS: The serial run output file is scientifically identical to the parallel run output file!"
#   echo "PASS: The maximum absolute difference is less than 1e-3 and the maximum relative difference is less than 1e-5!"
#else
#   echo "FAIL: The serial run output file is NOT scientifically identical to the parallel run output file!"
#fi

echo "Creating the runtime vs. number of cores figure ..."

tempdata=$(printf "%b" "$DATA")

  gnuplot -persist <<-EOFMarker
      \$Mydata << EOD
$tempdata
EOD
      # Set terminal to png or pdf for output
      set terminal pngcairo enhanced font 'Arial, 12'
      set output 'VPU_mpi_03S_runtime.png'

      # Set title and labels
      set title "MPI parallel number of cores vs runtime (03S)"
      set xlabel 'Number of cores'
      set ylabel "Wall clock time (mins) " offset 0,0,0
      unset key
      set yrange [0:*]
      set grid

      # Plot data from file
      plot \$Mydata using 1:(\$2/60) with linespoints

EOFMarker

exit 0
