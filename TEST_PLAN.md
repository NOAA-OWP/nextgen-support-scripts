# Build Cluster Script Test Plan

## Test Overview
This document outlines the test cases to verify the updated build_cluster.sh script handles dependencies, prompts, and build order correctly.

---

## Test 1: Development Build with nwm-cal-mgr

### Command
```bash
./parallel_works_scripts/build_cluster.sh --build-type=development nwm-cal-mgr ngen
```

### Expected Behavior
1. **Auto-dependency inclusion**: Script should auto-add `ngen-forcing` with message:
   ```
   Auto-adding dependency: ngen-forcing (required by ngen)
   ```

2. **Build order**: Should build in this exact order:
   - ngen-forcing (`:latest` tag) - all 3 Dockerfiles
   - ngen (`:latest` tag)
   - nwm-cal-mgr (`:latest` tag)

3. **Build arguments**:
   - ngen build should show: `Building ngen (development) Docker image with NGEN_FORCING_TAG=latest`
   - nwm-cal-mgr build should show: `Building nwm-cal-mgr (development) Docker image with NGEN_IMAGE_TAG=latest`

4. **No extra prompts**: Should NOT see any prompts asking "Which ngen-forcing Docker image tag do you want ngen to use?"

### Verification Checklist
- [ ] ngen-forcing auto-added to SELECTED_REPOS
- [ ] Build order: ngen-forcing → ngen → nwm-cal-mgr
- [ ] ngen uses NGEN_FORCING_TAG=latest
- [ ] nwm-cal-mgr uses NGEN_IMAGE_TAG=latest
- [ ] No redundant tag prompts

---

## Test 2: Development Build with nwm-fcst-mgr

### Command
```bash
./parallel_works_scripts/build_cluster.sh --build-type=development nwm-fcst-mgr ngen
```

### Expected Behavior
Same as Test 1, but with nwm-fcst-mgr:
1. Auto-add `ngen-forcing`
2. Build order: ngen-forcing → ngen → nwm-fcst-mgr
3. ngen uses `NGEN_FORCING_TAG=latest`
4. nwm-fcst-mgr uses `NGEN_IMAGE_TAG=latest`

### Verification Checklist
- [ ] ngen-forcing auto-added to SELECTED_REPOS
- [ ] Build order: ngen-forcing → ngen → nwm-fcst-mgr
- [ ] ngen uses NGEN_FORCING_TAG=latest
- [ ] nwm-fcst-mgr uses NGEN_IMAGE_TAG=latest
- [ ] No redundant tag prompts

---

## Test 3: Release Build with nwm-cal-mgr

### Command
```bash
./parallel_works_scripts/build_cluster.sh --build-type=release nwm-cal-mgr ngen
```

### Expected Prompts (in order)
1. "Enter ngen-forcing tag (shared for bmi/lumped/coastal):" → e.g., `v1.0.0`
2. "Enter ngen tag:" → e.g., `v2.0.0`
3. "Enter ngen-forcing tag (used by ngen):" → **Should NOT appear** (already set)
4. "Enter ngen tag (used by nwm-cal-mgr/nwm-fcst-mgr):" → **Should NOT appear** (already set)
5. "Enter nwm-cal-mgr tag:" → e.g., `v3.0.0`

### Expected Behavior
1. **Auto-dependency inclusion**: Script should auto-add `ngen-forcing`
2. **Build order**: ngen-forcing (v1.0.0) → ngen (v2.0.0) → nwm-cal-mgr (v3.0.0)
3. **Build arguments**:
   - ngen: `Building ngen Docker image with NGEN_FORCING_TAG=v1.0.0`
   - nwm-cal-mgr: `Building nwm-cal-mgr Docker image with NGEN_IMAGE_TAG=v2.0.0`

### Verification Checklist
- [ ] ngen-forcing auto-added to SELECTED_REPOS
- [ ] Only prompted ONCE for each repo's tag
- [ ] No redundant "Which X tag do you want Y to use?" prompts
- [ ] Build order: ngen-forcing → ngen → nwm-cal-mgr
- [ ] ngen uses ngen-forcing's specified tag
- [ ] nwm-cal-mgr uses ngen's specified tag

---

## Test 4: Release Build with nwm-fcst-mgr

### Command
```bash
./parallel_works_scripts/build_cluster.sh --build-type=release nwm-fcst-mgr ngen
```

### Expected Behavior
Same as Test 3, but with nwm-fcst-mgr instead of nwm-cal-mgr.

### Verification Checklist
- [ ] ngen-forcing auto-added to SELECTED_REPOS
- [ ] Only prompted ONCE for each repo's tag
- [ ] No redundant prompts
- [ ] Build order: ngen-forcing → ngen → nwm-fcst-mgr
- [ ] ngen uses ngen-forcing's specified tag
- [ ] nwm-fcst-mgr uses ngen's specified tag

---

## Test 5: Feature Build with ngen

### Command
```bash
./parallel_works_scripts/build_cluster.sh --build-type=feature ngen
```

### Expected Prompts
1. "Enter ngen branch:" → e.g., `feature/new-functionality`
2. "Enter ngen-forcing branch (used by ngen):" → e.g., `feature/forcing-update`
3. **Should NOT see**: "Image source for 'ngen' [build/pull]" prompt
4. **Should NOT see**: Any default values like "(default: feature)"

### Expected Behavior
1. **Auto-dependency inclusion**: Script should auto-add `ngen-forcing`
2. **No pull prompts**: Should NOT ask to pull any images
3. **Branch name validation**: Should reject empty branch names with error
4. **Docker tags**:
   - ngen-forcing images tagged as: `feature-forcing-update` (sanitized: `/` → `-`)
   - ngen image tagged as: `feature-new-functionality`
5. **Build arguments**:
   - ngen: `Building ngen (feature) Docker image with NGEN_FORCING_TAG=feature-forcing-update`
6. **No SIF files**: `ngen` and `ngen-bmi-forcing` are Docker-only — no `ngen-*.sif` or `ngen-bmi-forcing-*.sif` should be produced. The ngen binary and forcing engine are accessed via `nwm-cal-mgr.sif` at runtime.

### Verification Checklist
- [ ] ngen-forcing auto-added to SELECTED_REPOS
- [ ] NO "Image source [build/pull]" prompts
- [ ] NO default branch values in prompts
- [ ] Branch name required (empty rejected)
- [ ] Docker tags use actual branch names (sanitized)
- [ ] NO `ngen-*.sif` or `ngen-bmi-forcing-*.sif` created under `/ngencerf-app/singularity`
- [ ] All images built locally (no pulling)
- [ ] ngen uses ngen-forcing's branch-based tag

---

## Test 6: Feature Build with nwm-cal-mgr

### Command
```bash
./parallel_works_scripts/build_cluster.sh --build-type=feature nwm-cal-mgr
```

### Expected Prompts
1. "Enter nwm-cal-mgr branch:" → e.g., `feature/calibration-improvements`
2. "Enter ngen branch (used by nwm-cal-mgr/nwm-fcst-mgr):" → e.g., `feature/ngen-updates`
3. "Enter ngen-forcing branch (used by ngen):" → e.g., `development`

### Expected Behavior
1. **Auto-dependency inclusion**: Should auto-add BOTH `ngen` AND `ngen-forcing`:
   ```
   Auto-adding dependency: ngen (required by nwm-cal-mgr)
   Auto-adding dependency: ngen-forcing (required by ngen)
   ```
2. **Build order**: ngen-forcing → ngen → nwm-cal-mgr
3. **Docker tags use branch names**:
   - ngen-forcing: `development`
   - ngen: `feature-ngen-updates`
   - nwm-cal-mgr: `feature-calibration-improvements`
4. **Build arguments**:
   - ngen: `NGEN_FORCING_TAG=development`
   - nwm-cal-mgr: `NGEN_IMAGE_TAG=feature-ngen-updates`

### Verification Checklist
- [ ] Both ngen and ngen-forcing auto-added
- [ ] NO pull prompts
- [ ] NO default branch values
- [ ] Build order: ngen-forcing → ngen → nwm-cal-mgr
- [ ] All Docker tags use actual branch names
- [ ] SIF files use actual branch names
- [ ] All built locally

---

## Test 7: Feature Build with nwm-verf

### Command
```bash
./parallel_works_scripts/build_cluster.sh --build-type=feature nwm-verf
```

### Expected Prompts
1. "Enter nwm-verf branch:" → e.g., `feature/verification-tool`
2. "Enter nwm-eval-mgr branch (used by nwm-verf):" → e.g., `development`

### Expected Behavior
1. **No auto-dependencies**: nwm-verf doesn't depend on ngen/ngen-forcing
2. **Build arguments**: `NWM_EVAL_MGR_TAG=development`
3. **Docker tag**: `feature-verification-tool`
4. **SIF file**: `nwm-verf-feature-verification-tool-{timestamp}.sif`

### Verification Checklist
- [ ] NO pull prompts
- [ ] NO default branch values
- [ ] Docker tag uses actual branch name
- [ ] SIF file uses actual branch name
- [ ] Built locally

---

## General Verification (All Tests)

### Things That Should NEVER Appear
- [ ] "Which <repo> Docker image tag do you want <repo> to use?" prompt
- [ ] Default values like "(default: feature)" in feature build prompts
- [ ] Pull prompts for feature builds
- [ ] Generic ":feature" tag in any output

### Things That Should Always Appear
- [ ] Auto-dependency messages when dependencies added
- [ ] Clear logging showing which tags/branches are being used
- [ ] Proper build order (dependencies first)

---

## Quick Test Commands

```bash
# Development builds
./parallel_works_scripts/build_cluster.sh --build-type=development nwm-cal-mgr ngen
./parallel_works_scripts/build_cluster.sh --build-type=development nwm-fcst-mgr ngen
./parallel_works_scripts/build_cluster.sh --build-type=development all

# Release builds (interactive - will prompt for tags)
./parallel_works_scripts/build_cluster.sh --build-type=release ngen
./parallel_works_scripts/build_cluster.sh --build-type=release nwm-cal-mgr ngen
./parallel_works_scripts/build_cluster.sh --build-type=release nwm-fcst-mgr ngen
./parallel_works_scripts/build_cluster.sh --build-type=release nwm-verf

# Feature builds (interactive - will prompt for branches)
./parallel_works_scripts/build_cluster.sh --build-type=feature ngen
./parallel_works_scripts/build_cluster.sh --build-type=feature nwm-cal-mgr
./parallel_works_scripts/build_cluster.sh --build-type=feature nwm-verf
```

---

## Debugging Tips

If something goes wrong, check:

1. **Auto-dependency inclusion**: Look for "Auto-adding dependency:" messages
2. **Build order**: Check the order of Docker build commands in output
3. **Tags/branches used**: Look for "with NGEN_FORCING_TAG=" or "with NGEN_IMAGE_TAG=" in build output
4. **SIF file names**: Check the actual .sif files created in the singularity directory
5. **Prompts**: Count how many times you're asked for the same information

Use `set -x` at the top of the script temporarily to see detailed execution if needed.
