#!/bin/bash

# ==============================================================================
# Test Script for build_cluster.sh
# ==============================================================================
# This script runs integration tests to verify build_cluster.sh behavior:
# - Build order (dependencies built first)
# - Correct dependency tags used in builds
# - Feature builds use branch names, not "feature"
# - No unwanted prompts
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
# ==============================================================================

# Keep pipefail for accurate pipeline status checks, but avoid `set -e` so that
# individual test failures don't abort the entire suite.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/build_cluster.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0
TEST_OUTPUT_DIR="/tmp/build_cluster_tests_$(date +%s)"
mkdir -p "$TEST_OUTPUT_DIR"

# Estimated test durations in seconds.
# Note: ngen and ngen-bmi-forcing no longer produce SIFs (Docker-only), so these
# estimates are higher than actual post-refactor runs. Recalibrate after the
# next full test pass.
TEST1_DURATION=3000  # 50 minutes - fresh dev build with dependencies
TEST2_DURATION=2700  # 45 minutes - dev build, some cached layers but still rebuilds most
TEST3_DURATION=3300  # 55 minutes - release build with --no-cache and tag checkouts
TEST4_DURATION=3000  # 50 minutes - release build, similar to Test 3
TEST5_DURATION=2100  # 35 minutes - feature build with ngen
TEST6_DURATION=2700  # 45 minutes - feature build with nwm-cal-mgr and dependencies
TEST7_DURATION=1800  # 30 minutes - feature build with ngen using existing ngen-forcing tag
TEST1_STEPS=5
TEST2_STEPS=5
TEST3_STEPS=5
TEST4_STEPS=5
TEST5_STEPS=8
TEST6_STEPS=6
TEST7_STEPS=5
TOTAL_ESTIMATED_DURATION=$((TEST1_DURATION + TEST2_DURATION + TEST3_DURATION + TEST4_DURATION + TEST5_DURATION + TEST6_DURATION + TEST7_DURATION))
SCRIPT_START_EPOCH=$(date +%s)
COMPLETED_SECONDS=0

format_duration() {
    local total_seconds="$1"
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    local parts=()

    if (( hours > 0 )); then
        parts+=("${hours}h")
    fi

    if (( minutes > 0 )); then
        parts+=("${minutes}m")
    fi

    if (( hours == 0 && minutes == 0 )); then
        parts+=("${seconds}s")
    fi

    echo "${parts[*]}"
}

print_test_progress() {
    local test_num="$1"
    local step="$2"
    local total_steps="$3"
    local description="$4"

    local percent=0
    if (( total_steps > 0 )); then
        percent=$(( (step * 100) / total_steps ))
    fi

    echo -e "${YELLOW}Test ${test_num} progress:${NC} [${step}/${total_steps}] ${percent}% - ${description}"
}

print_progress() {
    local completed_seconds="$1"
    local context="$2"
    local elapsed=$(( $(date +%s) - SCRIPT_START_EPOCH ))
    local capped_completed="$completed_seconds"

    if (( capped_completed > TOTAL_ESTIMATED_DURATION )); then
        capped_completed=$TOTAL_ESTIMATED_DURATION
    fi

    local percent_complete=0
    if (( TOTAL_ESTIMATED_DURATION > 0 )); then
        percent_complete=$(( (capped_completed * 100) / TOTAL_ESTIMATED_DURATION ))
    fi

    local remaining=$((TOTAL_ESTIMATED_DURATION - capped_completed))
    if (( remaining < 0 )); then
        remaining=0
    fi

    echo -e "${YELLOW}Progress:${NC} ${percent_complete}% complete (elapsed $(format_duration "$elapsed"), ~$(format_duration "$remaining") remaining) - ${context}"
}

# Print test header with estimated duration
print_test_header() {
    local test_num="$1"
    local test_name="$2"
    local duration_seconds="$3"

    local start_time=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    echo -e "\n${BOLD}Running Test ${test_num}: ${test_name}${NC}"
    echo -e "  Started: ${start_time}"
    echo -e "  Estimated duration: ~$((duration_seconds / 60)) minutes"
}

# Print test result
print_result() {
    local test_name="$1"
    local result="$2"
    local details="$3"

    if [[ "$result" == "PASS" ]]; then
        echo -e "${GREEN}✓ PASS${NC}: $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC}: $test_name"
        if [[ -n "$details" ]]; then
            echo -e "  ${YELLOW}Details:${NC} $details"
        fi
        ((TESTS_FAILED++))
    fi
}

# Verify build order in output
get_build_line_number() {
    local output_file="$1"
    local repo="$2"

    local line=""
    if [[ "$repo" == "ngen-forcing" ]]; then
        line=$(grep -n "Building ngen-bmi-forcing " "$output_file" 2>/dev/null || true)
    else
        line=$(grep -n "Building ${repo} " "$output_file" 2>/dev/null || true)
    fi

    line=$(echo "$line" | head -1)
    [[ -n "$line" ]] && echo "${line%%:*}"

    # Always return success so callers can handle missing lines without the
    # script exiting early.
    return 0
}

verify_build_order() {
    local output_file="$1"
    local expected_order=("$@")
    unset 'expected_order[0]'  # remove first element (output_file)

    local line_numbers=()
    for repo in "${expected_order[@]}"; do
        local line_num
        line_num=$(get_build_line_number "$output_file" "$repo")
        if [[ -z "$line_num" ]]; then
            echo "ERROR: Could not find build for $repo"
            return 1
        fi
        line_numbers+=("$line_num:$repo")
    done

    # Print found line numbers
    echo "  Build order found at lines: ${line_numbers[*]}"

    # Sort by line number and verify order
    local sorted_repos=($(printf '%s\n' "${line_numbers[@]}" | sort -n | cut -d: -f2))

    # Convert expected_order to 0-indexed array for comparison
    local expected_array=("${expected_order[@]}")

    for i in "${!expected_array[@]}"; do
        if [[ "${expected_array[$i]}" != "${sorted_repos[$i]}" ]]; then
            echo "ERROR: Expected ${expected_array[$i]} but found ${sorted_repos[$i]} at position $i"
            return 1
        fi
    done

    return 0
}

# Verify build argument used
verify_build_arg() {
    local output_file="$1"
    local repo="$2"
    local arg_name="$3"
    local expected_value="$4"

    local line_num
    line_num=$(get_build_line_number "$output_file" "$repo")
    if [[ -z "$line_num" ]]; then
        echo "ERROR: Could not find build line for $repo while checking ${arg_name}"
        return 1
    fi

    local line_text
    line_text=$(sed -n "${line_num}p" "$output_file")
    local actual_value=""
    if [[ "$line_text" =~ ${arg_name}=([^[:space:]]+) ]]; then
        actual_value="${BASH_REMATCH[1]}"
    fi

    if [[ "$actual_value" != "$expected_value" ]]; then
        echo "ERROR: Expected ${arg_name}=${expected_value} but found ${arg_name}=${actual_value}"
        return 1
    fi

    echo "  Found ${arg_name}=${actual_value} at line ${line_num}"
    return 0
}

# Verify no prompts in output
verify_no_prompt() {
    local output_file="$1"
    local prompt_text="$2"

    if grep -q "$prompt_text" "$output_file" 2>/dev/null; then
        echo "ERROR: Found unwanted prompt: $prompt_text"
        return 1
    fi

    return 0
}

# ==============================================================================
# TEST 1: Development build with nwm-cal-mgr
# ==============================================================================
print_test_header "1" "Development build with nwm-cal-mgr" "$TEST1_DURATION"
TEST1_OUTPUT="${TEST_OUTPUT_DIR}/test1_dev_cal_mgr.log"
TEST1_START=$(date +%s)
print_progress "$COMPLETED_SECONDS" "Starting Test 1: Development build with nwm-cal-mgr (ngen-forcing -> ngen -> nwm-cal-mgr)"

if ! "$BUILD_SCRIPT" --build-type=development nwm-cal-mgr ngen > "$TEST1_OUTPUT" 2>&1; then
    print_result "Test 1: Development build (nwm-cal-mgr) - execution" "FAIL" "Build script failed"
    print_test_progress "1" 1 "$TEST1_STEPS" "Build failed"
else
    print_result "Test 1: Development build (nwm-cal-mgr) - execution" "PASS"
    print_test_progress "1" 1 "$TEST1_STEPS" "Build completed"

    # Verify build order: ngen-forcing -> ngen -> nwm-cal-mgr
    if verify_build_order "$TEST1_OUTPUT" "ngen-forcing" "ngen" "nwm-cal-mgr"; then
        print_result "Test 1: Build order (forcing->ngen->cal-mgr)" "PASS"
    else
        print_result "Test 1: Build order (forcing->ngen->cal-mgr)" "FAIL" "Incorrect build order"
    fi
    print_test_progress "1" 2 "$TEST1_STEPS" "Verified build order"

    # Verify ngen uses ngen-forcing:latest
    if verify_build_arg "$TEST1_OUTPUT" "ngen" "NGEN_FORCING_TAG" "latest"; then
        print_result "Test 1: ngen uses NGEN_FORCING_TAG=latest" "PASS"
    else
        print_result "Test 1: ngen uses NGEN_FORCING_TAG=latest" "FAIL" "Wrong tag used"
    fi
    print_test_progress "1" 3 "$TEST1_STEPS" "Verified ngen uses ngen-forcing:latest"

    # Verify nwm-cal-mgr uses ngen:latest
    if verify_build_arg "$TEST1_OUTPUT" "nwm-cal-mgr" "NGEN_IMAGE_TAG" "latest"; then
        print_result "Test 1: nwm-cal-mgr uses NGEN_IMAGE_TAG=latest" "PASS"
    else
        print_result "Test 1: nwm-cal-mgr uses NGEN_IMAGE_TAG=latest" "FAIL" "Wrong tag used"
    fi
    print_test_progress "1" 4 "$TEST1_STEPS" "Verified nwm-cal-mgr uses ngen:latest"

    # Verify no unwanted prompts
    if verify_no_prompt "$TEST1_OUTPUT" "Which.*Docker image tag"; then
        print_result "Test 1: No unwanted tag prompts" "PASS"
    else
        print_result "Test 1: No unwanted tag prompts" "FAIL" "Found unwanted prompt"
    fi
    print_test_progress "1" 5 "$TEST1_STEPS" "Checked for unwanted tag prompts"
fi
TEST1_ELAPSED=$(( $(date +%s) - TEST1_START ))
COMPLETED_SECONDS=$((COMPLETED_SECONDS + TEST1_ELAPSED))
print_progress "$COMPLETED_SECONDS" "Finished Test 1 (took $(format_duration "$TEST1_ELAPSED"))"

# ==============================================================================
# TEST 2: Development build with nwm-fcst-mgr
# ==============================================================================
print_test_header "2" "Development build with nwm-fcst-mgr" "$TEST2_DURATION"
TEST2_OUTPUT="${TEST_OUTPUT_DIR}/test2_dev_fcst_mgr.log"
TEST2_START=$(date +%s)
print_progress "$COMPLETED_SECONDS" "Starting Test 2: Development build with nwm-fcst-mgr (ngen-forcing -> ngen -> nwm-fcst-mgr)"

if ! "$BUILD_SCRIPT" --build-type=development nwm-fcst-mgr ngen > "$TEST2_OUTPUT" 2>&1; then
    print_result "Test 2: Development build (nwm-fcst-mgr) - execution" "FAIL" "Build script failed"
    print_test_progress "2" 1 "$TEST2_STEPS" "Build failed"
else
    print_result "Test 2: Development build (nwm-fcst-mgr) - execution" "PASS"
    print_test_progress "2" 1 "$TEST2_STEPS" "Build completed"

    # Verify build order: ngen-forcing -> ngen -> nwm-fcst-mgr
    if verify_build_order "$TEST2_OUTPUT" "ngen-forcing" "ngen" "nwm-fcst-mgr"; then
        print_result "Test 2: Build order (forcing->ngen->fcst-mgr)" "PASS"
    else
        print_result "Test 2: Build order (forcing->ngen->fcst-mgr)" "FAIL" "Incorrect build order"
    fi
    print_test_progress "2" 2 "$TEST2_STEPS" "Verified build order"

    # Verify ngen uses ngen-forcing:latest
    if verify_build_arg "$TEST2_OUTPUT" "ngen" "NGEN_FORCING_TAG" "latest"; then
        print_result "Test 2: ngen uses NGEN_FORCING_TAG=latest" "PASS"
    else
        print_result "Test 2: ngen uses NGEN_FORCING_TAG=latest" "FAIL" "Wrong tag used"
    fi
    print_test_progress "2" 3 "$TEST2_STEPS" "Verified ngen uses ngen-forcing:latest"

    # Verify nwm-fcst-mgr uses ngen:latest
    if verify_build_arg "$TEST2_OUTPUT" "nwm-fcst-mgr" "NGEN_IMAGE_TAG" "latest"; then
        print_result "Test 2: nwm-fcst-mgr uses NGEN_IMAGE_TAG=latest" "PASS"
    else
        print_result "Test 2: nwm-fcst-mgr uses NGEN_IMAGE_TAG=latest" "FAIL" "Wrong tag used"
    fi
    print_test_progress "2" 4 "$TEST2_STEPS" "Verified nwm-fcst-mgr uses ngen:latest"

    # Verify no unwanted prompts
    if verify_no_prompt "$TEST2_OUTPUT" "Which.*Docker image tag"; then
        print_result "Test 2: No unwanted tag prompts" "PASS"
    else
        print_result "Test 2: No unwanted tag prompts" "FAIL" "Found unwanted prompt"
    fi
    print_test_progress "2" 5 "$TEST2_STEPS" "Checked for unwanted tag prompts"
fi
TEST2_ELAPSED=$(( $(date +%s) - TEST2_START ))
COMPLETED_SECONDS=$((COMPLETED_SECONDS + TEST2_ELAPSED))
print_progress "$COMPLETED_SECONDS" "Finished Test 2 (took $(format_duration "$TEST2_ELAPSED"))"

# ==============================================================================
# TEST 3: Release build with nwm-cal-mgr
# ==============================================================================
print_test_header "3" "Release build with nwm-cal-mgr" "$TEST3_DURATION"
TEST3_OUTPUT="${TEST_OUTPUT_DIR}/test3_release_cal_mgr.log"
TEST3_START=$(date +%s)
print_progress "$COMPLETED_SECONDS" "Starting Test 3: Release build with nwm-cal-mgr (ngen-forcing -> ngen -> nwm-cal-mgr)"

# Provide all tags via command line to avoid interactive prompts (pin to known release tags)
"$BUILD_SCRIPT" --build-type=release --source-default=build \
    --tag=ngen-forcing:3.1.2.1.0 \
    --tag=ngen:3.1.2.1.0 \
    --tag=nwm-cal-mgr:3.1.2.1.0 \
    nwm-cal-mgr ngen > "$TEST3_OUTPUT" 2>&1

if [[ $? -ne 0 ]]; then
    print_result "Test 3: Release build (nwm-cal-mgr) - execution" "FAIL" "Build script failed"
else
    print_result "Test 3: Release build (nwm-cal-mgr) - execution" "PASS"
    print_test_progress "3" 1 "$TEST3_STEPS" "Build completed"

    # Verify build order
    if verify_build_order "$TEST3_OUTPUT" "ngen-forcing" "ngen" "nwm-cal-mgr"; then
        print_result "Test 3: Build order (forcing->ngen->cal-mgr)" "PASS"
    else
        print_result "Test 3: Build order (forcing->ngen->cal-mgr)" "FAIL" "Incorrect build order"
    fi
    print_test_progress "3" 2 "$TEST3_STEPS" "Verified build order"

    # Verify ngen uses ngen-forcing release tag
    if verify_build_arg "$TEST3_OUTPUT" "ngen" "NGEN_FORCING_TAG" "3.1.2.1.0"; then
        print_result "Test 3: ngen uses NGEN_FORCING_TAG=3.1.2.1.0" "PASS"
    else
        print_result "Test 3: ngen uses NGEN_FORCING_TAG=3.1.2.1.0" "FAIL" "Wrong tag used"
    fi
    print_test_progress "3" 3 "$TEST3_STEPS" "Verified ngen uses release forcing tag"

    # Verify nwm-cal-mgr uses ngen release tag
    if verify_build_arg "$TEST3_OUTPUT" "nwm-cal-mgr" "NGEN_IMAGE_TAG" "3.1.2.1.0"; then
        print_result "Test 3: nwm-cal-mgr uses NGEN_IMAGE_TAG=3.1.2.1.0" "PASS"
    else
        print_result "Test 3: nwm-cal-mgr uses NGEN_IMAGE_TAG=3.1.2.1.0" "FAIL" "Wrong tag used"
    fi
    print_test_progress "3" 4 "$TEST3_STEPS" "Verified nwm-cal-mgr uses ngen release tag"

    # Verify no unwanted prompts
    if verify_no_prompt "$TEST3_OUTPUT" "Which.*Docker image tag"; then
        print_result "Test 3: No unwanted tag prompts" "PASS"
    else
        print_result "Test 3: No unwanted tag prompts" "FAIL" "Found unwanted prompt"
    fi
    print_test_progress "3" 5 "$TEST3_STEPS" "Checked for unwanted tag prompts"
fi
TEST3_ELAPSED=$(( $(date +%s) - TEST3_START ))
COMPLETED_SECONDS=$((COMPLETED_SECONDS + TEST3_ELAPSED))
print_progress "$COMPLETED_SECONDS" "Finished Test 3 (took $(format_duration "$TEST3_ELAPSED"))"

# ==============================================================================
# TEST 4: Release build with nwm-fcst-mgr
# ==============================================================================
print_test_header "4" "Release build with nwm-fcst-mgr" "$TEST4_DURATION"
TEST4_OUTPUT="${TEST_OUTPUT_DIR}/test4_release_fcst_mgr.log"
TEST4_START=$(date +%s)
print_progress "$COMPLETED_SECONDS" "Starting Test 4: Release build with nwm-fcst-mgr (ngen-forcing -> ngen -> nwm-fcst-mgr)"

# Provide all tags via command line to avoid interactive prompts (pin to known release tags)
"$BUILD_SCRIPT" --build-type=release --source-default=build \
    --tag=ngen-forcing:3.1.2.1.0 \
    --tag=ngen:3.1.2.1.0 \
    --tag=nwm-fcst-mgr:3.1.2.1.0 \
    nwm-fcst-mgr ngen > "$TEST4_OUTPUT" 2>&1

if [[ $? -ne 0 ]]; then
    print_result "Test 4: Release build (nwm-fcst-mgr) - execution" "FAIL" "Build script failed"
else
    print_result "Test 4: Release build (nwm-fcst-mgr) - execution" "PASS"
    print_test_progress "4" 1 "$TEST4_STEPS" "Build completed"

    # Verify build order
    if verify_build_order "$TEST4_OUTPUT" "ngen-forcing" "ngen" "nwm-fcst-mgr"; then
        print_result "Test 4: Build order (forcing->ngen->fcst-mgr)" "PASS"
    else
        print_result "Test 4: Build order (forcing->ngen->fcst-mgr)" "FAIL" "Incorrect build order"
    fi
    print_test_progress "4" 2 "$TEST4_STEPS" "Verified build order"

    # Verify ngen uses ngen-forcing release tag
    if verify_build_arg "$TEST4_OUTPUT" "ngen" "NGEN_FORCING_TAG" "3.1.2.1.0"; then
        print_result "Test 4: ngen uses NGEN_FORCING_TAG=3.1.2.1.0" "PASS"
    else
        print_result "Test 4: ngen uses NGEN_FORCING_TAG=3.1.2.1.0" "FAIL" "Wrong tag used"
    fi
    print_test_progress "4" 3 "$TEST4_STEPS" "Verified ngen uses release forcing tag"

    # Verify nwm-fcst-mgr uses ngen release tag
    if verify_build_arg "$TEST4_OUTPUT" "nwm-fcst-mgr" "NGEN_IMAGE_TAG" "3.1.2.1.0"; then
        print_result "Test 4: nwm-fcst-mgr uses NGEN_IMAGE_TAG=3.1.2.1.0" "PASS"
    else
        print_result "Test 4: nwm-fcst-mgr uses NGEN_IMAGE_TAG=3.1.2.1.0" "FAIL" "Wrong tag used"
    fi
    print_test_progress "4" 4 "$TEST4_STEPS" "Verified nwm-fcst-mgr uses ngen release tag"

    # Verify no unwanted prompts
    if verify_no_prompt "$TEST4_OUTPUT" "Which.*Docker image tag"; then
        print_result "Test 4: No unwanted tag prompts" "PASS"
    else
        print_result "Test 4: No unwanted tag prompts" "FAIL" "Found unwanted prompt"
    fi
    print_test_progress "4" 5 "$TEST4_STEPS" "Checked for unwanted tag prompts"
fi
TEST4_ELAPSED=$(( $(date +%s) - TEST4_START ))
COMPLETED_SECONDS=$((COMPLETED_SECONDS + TEST4_ELAPSED))
print_progress "$COMPLETED_SECONDS" "Finished Test 4 (took $(format_duration "$TEST4_ELAPSED"))"

# ==============================================================================
# TEST 5: Feature build with ngen
# ==============================================================================
print_test_header "5" "Feature build with ngen" "$TEST5_DURATION"
TEST5_OUTPUT="${TEST_OUTPUT_DIR}/test5_feature_ngen.log"
TEST5_START=$(date +%s)
print_progress "$COMPLETED_SECONDS" "Starting Test 5: Feature build with ngen (ngen-forcing -> ngen)"

"$BUILD_SCRIPT" --build-type=feature --branch=ngen:development ngen > "$TEST5_OUTPUT" 2>&1

if [[ $? -ne 0 ]]; then
    print_result "Test 5: Feature build (ngen) - execution" "FAIL" "Build script failed"
else
    print_result "Test 5: Feature build (ngen) - execution" "PASS"
    print_test_progress "5" 1 "$TEST5_STEPS" "Build completed"

    # Verify branch name used in Docker tag (not "feature")
    if grep -q "ngen-bmi-forcing:development" "$TEST5_OUTPUT"; then
        print_result "Test 5: ngen-forcing uses branch name in tag" "PASS"
    else
        print_result "Test 5: ngen-forcing uses branch name in tag" "FAIL" "Not using branch name"
    fi
    print_test_progress "5" 2 "$TEST5_STEPS" "Verified ngen-forcing tag uses branch"

    if grep -q "ngen:development" "$TEST5_OUTPUT"; then
        print_result "Test 5: ngen uses branch name in tag" "PASS"
    else
        print_result "Test 5: ngen uses branch name in tag" "FAIL" "Not using branch name"
    fi
    print_test_progress "5" 3 "$TEST5_STEPS" "Verified ngen tag uses branch"

    # Verify not using generic "feature" tag
    if ! grep -q "ngen:feature[^/]" "$TEST5_OUTPUT"; then
        print_result "Test 5: Not using generic 'feature' tag" "PASS"
    else
        print_result "Test 5: Not using generic 'feature' tag" "FAIL" "Found generic feature tag"
    fi
    print_test_progress "5" 4 "$TEST5_STEPS" "Checked for generic feature tag"

    # Verify all builds are local (no pulling)
    if ! grep -q "Pulling.*Docker image" "$TEST5_OUTPUT"; then
        print_result "Test 5: All images built locally (no pulling)" "PASS"
    else
        print_result "Test 5: All images built locally (no pulling)" "FAIL" "Found pull operation"
    fi
    print_test_progress "5" 5 "$TEST5_STEPS" "Confirmed images built locally"

    # Verify no prompts about image source (build/pull)
    if ! grep -q "Image source for.*\[build/pull\]" "$TEST5_OUTPUT"; then
        print_result "Test 5: No image source prompts" "PASS"
    else
        print_result "Test 5: No image source prompts" "FAIL" "Found image source prompt"
    fi
    print_test_progress "5" 6 "$TEST5_STEPS" "Checked for image source prompts"

    # Verify no default branch prompts
    if ! grep -q "default.*development\|default.*main" "$TEST5_OUTPUT"; then
        print_result "Test 5: No default branch in prompts" "PASS"
    else
        print_result "Test 5: No default branch in prompts" "FAIL" "Found default branch reference"
    fi
    print_test_progress "5" 7 "$TEST5_STEPS" "Checked for default branch prompts"

    # Verify no unwanted prompts
    if verify_no_prompt "$TEST5_OUTPUT" "Which.*Docker image tag"; then
        print_result "Test 5: No unwanted tag prompts" "PASS"
    else
        print_result "Test 5: No unwanted tag prompts" "FAIL" "Found unwanted prompt"
    fi
    print_test_progress "5" 8 "$TEST5_STEPS" "Checked for unwanted tag prompts"
fi
TEST5_ELAPSED=$(( $(date +%s) - TEST5_START ))
COMPLETED_SECONDS=$((COMPLETED_SECONDS + TEST5_ELAPSED))
print_progress "$COMPLETED_SECONDS" "Finished Test 5 (took $(format_duration "$TEST5_ELAPSED"))"

# ==============================================================================
# TEST 6: Feature build with nwm-cal-mgr
# ==============================================================================
print_test_header "6" "Feature build with nwm-cal-mgr" "$TEST6_DURATION"
TEST6_OUTPUT="${TEST_OUTPUT_DIR}/test6_feature_cal_mgr.log"
TEST6_START=$(date +%s)
print_progress "$COMPLETED_SECONDS" "Starting Test 6: Feature build with nwm-cal-mgr (ngen-forcing -> ngen -> nwm-cal-mgr)"

"$BUILD_SCRIPT" --build-type=feature --branch=nwm-cal-mgr:development nwm-cal-mgr > "$TEST6_OUTPUT" 2>&1

if [[ $? -ne 0 ]]; then
    print_result "Test 6: Feature build (nwm-cal-mgr) - execution" "FAIL" "Build script failed"
else
    print_result "Test 6: Feature build (nwm-cal-mgr) - execution" "PASS"
    print_test_progress "6" 1 "$TEST6_STEPS" "Build completed"

    # Verify branch name used in Docker tag
    if grep -q "nwm-cal-mgr:development" "$TEST6_OUTPUT"; then
        print_result "Test 6: nwm-cal-mgr uses branch name in tag" "PASS"
    else
        print_result "Test 6: nwm-cal-mgr uses branch name in tag" "FAIL" "Not using branch name"
    fi
    print_test_progress "6" 2 "$TEST6_STEPS" "Verified nwm-cal-mgr tag uses branch"

    # Verify not using generic "feature" tag
    if ! grep -q "nwm-cal-mgr:feature[^/]" "$TEST6_OUTPUT"; then
        print_result "Test 6: Not using generic 'feature' tag" "PASS"
    else
        print_result "Test 6: Not using generic 'feature' tag" "FAIL" "Found generic feature tag"
    fi
    print_test_progress "6" 3 "$TEST6_STEPS" "Checked for generic feature tag"

    # Verify all builds are local
    if ! grep -q "Pulling.*Docker image" "$TEST6_OUTPUT"; then
        print_result "Test 6: All images built locally (no pulling)" "PASS"
    else
        print_result "Test 6: All images built locally (no pulling)" "FAIL" "Found pull operation"
    fi
    print_test_progress "6" 4 "$TEST6_STEPS" "Confirmed images built locally"

    # Verify no image source prompts
    if ! grep -q "Image source for.*\[build/pull\]" "$TEST6_OUTPUT"; then
        print_result "Test 6: No image source prompts" "PASS"
    else
        print_result "Test 6: No image source prompts" "FAIL" "Found image source prompt"
    fi
    print_test_progress "6" 5 "$TEST6_STEPS" "Checked for image source prompts"

    # Verify no unwanted prompts
    if verify_no_prompt "$TEST6_OUTPUT" "Which.*Docker image tag"; then
        print_result "Test 6: No unwanted tag prompts" "PASS"
    else
        print_result "Test 6: No unwanted tag prompts" "FAIL" "Found unwanted prompt"
    fi
    print_test_progress "6" 6 "$TEST6_STEPS" "Checked for unwanted tag prompts"
fi
TEST6_ELAPSED=$(( $(date +%s) - TEST6_START ))
COMPLETED_SECONDS=$((COMPLETED_SECONDS + TEST6_ELAPSED))
print_progress "$COMPLETED_SECONDS" "Finished Test 6 (took $(format_duration "$TEST6_ELAPSED"))"

# ==============================================================================
# TEST 7: Feature build with ngen using existing ngen-forcing tag
# ==============================================================================
print_test_header "7" "Feature build with ngen using existing ngen-forcing tag" 1800
TEST7_OUTPUT="${TEST_OUTPUT_DIR}/test7_feature_ngen_existing_tag.log"
TEST7_START=$(date +%s)
print_progress "$COMPLETED_SECONDS" "Starting Test 7: Feature build with ngen using existing ngen-forcing tag"

# This tests the new functionality: building ngen from branch but using existing ngen-forcing:latest
"$BUILD_SCRIPT" --build-type=feature \
    --branch=ngen:development \
    --ngen-forcing-tag=latest \
    ngen > "$TEST7_OUTPUT" 2>&1

if [[ $? -ne 0 ]]; then
    print_result "Test 7: Feature build (ngen with existing forcing tag) - execution" "FAIL" "Build script failed"
    print_test_progress "7" 1 "$TEST7_STEPS" "Build failed"
else
    print_result "Test 7: Feature build (ngen with existing forcing tag) - execution" "PASS"
    print_test_progress "7" 1 "$TEST7_STEPS" "Build completed"

    # Verify ngen-forcing was NOT built (should use existing tag)
    if ! grep -q "Building ngen-bmi-forcing" "$TEST7_OUTPUT"; then
        print_result "Test 7: ngen-forcing not built (using existing tag)" "PASS"
    else
        print_result "Test 7: ngen-forcing not built (using existing tag)" "FAIL" "ngen-forcing was built"
    fi
    print_test_progress "7" 2 "$TEST7_STEPS" "Verified ngen-forcing not built"

    # Verify ngen was built
    if grep -q "Building ngen.*development" "$TEST7_OUTPUT"; then
        print_result "Test 7: ngen built from development branch" "PASS"
    else
        print_result "Test 7: ngen built from development branch" "FAIL" "ngen not built or wrong branch"
    fi
    print_test_progress "7" 3 "$TEST7_STEPS" "Verified ngen built from branch"

    # Verify ngen uses specified ngen-forcing tag
    if verify_build_arg "$TEST7_OUTPUT" "ngen" "NGEN_FORCING_TAG" "latest"; then
        print_result "Test 7: ngen uses NGEN_FORCING_TAG=latest" "PASS"
    else
        print_result "Test 7: ngen uses NGEN_FORCING_TAG=latest" "FAIL" "Wrong tag used"
    fi
    print_test_progress "7" 4 "$TEST7_STEPS" "Verified ngen uses existing forcing tag"

    # Verify message about using specified tag
    if grep -q "Using specified ngen-forcing tag: latest" "$TEST7_OUTPUT"; then
        print_result "Test 7: Confirms using specified ngen-forcing tag" "PASS"
    else
        print_result "Test 7: Confirms using specified ngen-forcing tag" "FAIL" "No confirmation message"
    fi
    print_test_progress "7" 5 "$TEST7_STEPS" "Verified confirmation message"
fi
TEST7_ELAPSED=$(( $(date +%s) - TEST7_START ))
COMPLETED_SECONDS=$((COMPLETED_SECONDS + TEST7_ELAPSED))
print_progress "$COMPLETED_SECONDS" "Finished Test 7 (took $(format_duration "$TEST7_ELAPSED"))"

# ==============================================================================
# SUMMARY
# ==============================================================================
echo -e "\n${BOLD}========================================${NC}"
echo -e "${BOLD}TEST SUMMARY${NC}"
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN}Passed:${NC} $TESTS_PASSED"
echo -e "${RED}Failed:${NC} $TESTS_FAILED"
echo -e "Total:  $((TESTS_PASSED + TESTS_FAILED))"
echo -e "\nTest outputs saved to: $TEST_OUTPUT_DIR"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}✓ ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "\n${RED}✗ SOME TESTS FAILED${NC}"
    echo -e "\nReview logs in $TEST_OUTPUT_DIR for details"
    exit 1
fi
