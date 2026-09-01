# build_cluster.sh Reference

## Purpose (high level)
`build_cluster.sh` builds and manages Singularity (SIF) images for a set of NGEN/NWM-related repositories. It can:
- Build or pull Docker images for selected repos.
- Convert Docker images to Singularity SIF files.
- Maintain stable symlinks to the latest SIFs.
- Enforce dependency order between repos (e.g., ngen-forcing -> ngen -> nwm-cal-mgr).
- Support interactive prompts or fully non-interactive CLI usage.
- Support three build modes: development, release, and feature.

The script targets repos in `/ngencerf-app` and writes SIF files under `/ngencerf-app/singularity`.

## Supported repos
- ngencerf-ui
- ngencerf-server
- ngencerf-docker
- ngen
- nwm-cal-mgr
- ngen-forcing
- nwm-fcst-mgr
- nwm-verf

Only a subset produce SIFs (all except `ngencerf-*`, `ngen`, and `ngen-bmi-forcing`). Docker images are still built for `ngen` and `ngen-bmi-forcing` because `nwm-cal-mgr` and `nwm-fcst-mgr` consume them via `FROM`; at runtime the ngen binary and forcing engine are accessed through `nwm-cal-mgr.sif`.

## Inputs and CLI options
- `--build-type=TYPE` with TYPE in `development`, `release`, `feature`.
- `--branch=REPO:BRANCH` per-repo branch (feature mode only).
- `--branch-default=BRANCH` global branch (feature mode only).
- `--source=REPO:MODE` per-repo image source for SIF-capable repos (`build` or `pull`).
- `--source-default=MODE` global image source default (`build` or `pull`).
- `--tag=REPO:TAG` per-repo tag (release or feature pulls).
- `--ngen-forcing-tag=TAG` sets dependency tag for ngen when building in feature mode.
- `--ngen-tag=TAG` sets dependency tag for nwm-cal-mgr/nwm-fcst-mgr in feature mode.
- Repo list as positional args, or `all` to select all.

Interactive mode is used if no args are passed and stdin is a TTY.

## Outputs
- Docker images built or pulled from `ghcr.io/ngwpc`.
- SIF files stored in `/ngencerf-app/singularity`.
- A stable symlink per SIF base name (e.g., `nwm-cal-mgr.sif`).
- A log file at `/ngencerf-app/singularity/build_cluster_<timestamp>.log`.
- A `.meta` file per SIF base name to track the last built image digest.

## Error handling and logging
- `set -e` and `set -o pipefail` stop on errors.
- A trap prints a standardized failure summary including line number and log location.
- All output is tee'd to the build log file.

## Step-by-step flow (general)
1. **Initialize constants and global state**
   - Defines base paths (`/ngencerf-app`, `/ngencerf-app/singularity`).
   - Declares lists of supported repos and repos that support build/pull mode.
   - Declares maps for branches, tags, image source modes, and dependency tags.

2. **Parse CLI arguments**
   - Collects build type, repo list, branches, tags, and image source overrides.
   - Validates:
     - Build type is one of development/release/feature.
     - `--branch` and `--branch-default` are not used in development mode.
     - Dependency tag flags are only used in feature mode.

3. **Initialize directories and logging**
   - Creates the Singularity output directory.
   - Starts logging to `/ngencerf-app/singularity/build_cluster_<timestamp>.log`.

4. **Interactive prompts (if needed)**
   - Prompts for build type if not provided.
   - Prompts for repos (default is all repos).
   - For non-feature builds, optionally prompts for per-repo image source (build/pull).
   - For feature builds, prompts for per-repo branches.

5. **Select default image sources**
   - Sets default build/pull mode per repo, optionally overridden by `--source-default`.
   - Feature builds force `build` for all SIF-capable repos.

6. **Expand repo selection and validate**
   - Expands `all` to the full repo list.
   - Rejects unknown repos.

7. **Auto-include dependencies**
   - Adds required upstream repos (e.g., `ngen-forcing` for `ngen`).
   - For development builds and interactive feature builds, adds downstream rebuilds
     when the user originally selected an upstream dependency.
   - Inherits branch choices for feature builds where reasonable.

8. **Order repos by dependency**
   - Ensures build order is `ngen-forcing -> ngen -> nwm-cal-mgr/nwm-fcst-mgr -> others`.

9. **Prompt for tags and dependency tags**
   - Release builds require explicit tags for all selected repos and for required
     dependencies (e.g., `nwm-eval-mgr` tag for `nwm-verf`).
   - Feature builds may require dependency branch/tag choices if the dependency
     is not being built in the same run.

10. **Validate dependency availability**
    - Warns about missing dependency images for feature builds when a dependency
      is not selected for build or pull.

11. **Execute build workflow**
    - Branches to one of three workflows:
      - `release`
      - `development`
      - `feature`

12. **Generate SIF files and update symlinks**
    - For each repo that produces a SIF, either uses the built image or pulls it.
    - Converts Docker image to SIF.
    - Updates a stable symlink to the newest SIF.
    - Writes a `.meta` file with image digest and SIF metadata to skip rebuilds
      when the image has not changed.

## Detailed workflow by build type

### Release workflow
1. **Checkout tagged repos**
   - Each repo is checked out to the specified tag using `git checkout <tag>`.
   - For `ngen`, submodules are updated after checkout.

2. **Build or pull Docker images**
   - `ngen-forcing` is handled first (dependency of `ngen`).
   - `ngen` builds with `NGEN_FORCING_IMAGE_TAG` set to the `ngen-forcing` tag.
   - `nwm-cal-mgr` and `nwm-fcst-mgr` build with `NGEN_IMAGE_TAG` set to the `ngen` tag.
   - `nwm-verf` builds with `NWM_EVAL_MGR_TAG` set to the `nwm-eval-mgr` tag.
   - If a repo is in `pull` mode, it will re-use a local image if present or pull
     from the registry.

3. **Build SIFs**
   - For each SIF-capable repo, the script converts the relevant Docker image
     (`ghcr.io/ngwpc/<image>:<tag>`) to a SIF file.
   - SIF filenames include the build type and tag and are time-stamped.
   - A symlink `<name>.sif` is updated to point to the most recent file.

### Development workflow
1. **Update repos to latest development branch**
   - `git fetch`, `git checkout development`, `git pull --rebase`.
   - Stashes and re-applies local changes.
   - Updates submodules for `ngen`.

2. **Build or pull Docker images**
   - `ngen-forcing` builds to `ngen-bmi-forcing:latest` (or pulls).
   - `ngen` builds with `NGEN_FORCING_IMAGE_TAG=latest` (or pulls).
   - `nwm-cal-mgr` and `nwm-fcst-mgr` build with `NGEN_IMAGE_TAG=latest`.
   - `nwm-verf` builds with `NWM_EVAL_MGR_TAG=development`.

3. **Build SIFs**
   - Converts `:latest` images into SIFs and updates symlinks.

### Feature workflow
1. **Update repos to feature branches**
   - Uses per-repo branch names (required), or inherited branches for
     auto-added dependencies.

2. **Build Docker images with branch-based tags**
   - Docker tags are derived from branch names by replacing `/` with `-`.
   - Dependency tags are either:
     - Derived from the dependency's branch, or
     - Explicitly set using `--ngen-forcing-tag` / `--ngen-tag`.

3. **Build SIFs**
   - Converts branch-tagged images to SIFs and updates symlinks.

## Key helper functions (what they do)
- `images_for_repo(repo)`
  - Maps repo names to Docker image and SIF base names.
- `repo_has_sif(repo)`
  - Excludes `ngencerf-*`, `ngen`, and `ngen-bmi-forcing` from SIF generation (Docker-only images).
- `set_image_source_defaults()`
  - Applies default build/pull modes; forces build for feature builds.
- `get_repo_branch(repo, build_type_default)`
  - Resolves branch priority: explicit per-repo branch, global default, or mode default.
- `get_docker_tag_for_repo(repo, build_type)`
  - Computes Docker tag: `latest` (development), sanitized branch (feature), or
    user-provided tag (release).
- `auto_include_dependencies()`
  - Adds required upstream repos and, in some cases, downstream rebuilds.
- `reorder_repos_by_dependency()`
  - Ensures build order respects dependency chain.
- `prompt_dependency_tags(build_type)`
  - Collects dependency tags or branch choices when required.
- `ensure_image_present(repo, image_ref, mode)`
  - Pulls an image only if it is missing locally.
- `build_singularity_container_update_symlink(build_type, sif_base, image_ref, tag)`
  - Builds the SIF, updates symlink, and writes `.meta` for change detection.
- `update_repo_branch(repo, default_branch)` and `checkout_repo_tag(repo, tag)`
  - Update repos by branch (development/feature) or tag (release).

## Dependency rules (summary)
- `ngen` requires `ngen-forcing`.
- `nwm-cal-mgr` and `nwm-fcst-mgr` require `ngen` (and transitively `ngen-forcing`).
- `nwm-verf` uses `nwm-eval-mgr` as a dependency tag in release builds or as a
  branch name in feature builds.

## Files and paths
- Script: `/home/christopher.nealen/nwm-automation-scripts/parallel_works_scripts/build_cluster.sh`
- Output SIF directory: `/ngencerf-app/singularity`
- Log files: `/ngencerf-app/singularity/build_cluster_<timestamp>.log`
- Repo base path: `/ngencerf-app/<repo>`

