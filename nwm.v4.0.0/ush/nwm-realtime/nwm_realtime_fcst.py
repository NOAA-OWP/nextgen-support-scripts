import argparse
import json
import os
import sys
from datetime import datetime

from nwm_forecast import NWMForecast
from nwm_region import Basin, VPU
from nwm_runner import NWMRunner


def main():
    parser = argparse.ArgumentParser(description="Run NWM realtime forecast")
    parser.add_argument(
        "--t0",
        required=True,
        metavar="YYYY-MM-DD HH:MM:SS",
        help="Forecast start time (T0) in UTC, e.g. '2026-05-20 12:00:00'",
    )
    parser.add_argument(
        "--config-name",
        default=NWMForecast.CONFIG_ANA,
        choices=[
            NWMForecast.CONFIG_ANA,
            NWMForecast.CONFIG_SHORT_RANGE,
            NWMForecast.CONFIG_MEDIUM_RANGE,
            NWMForecast.CONFIG_EXT_ANA,
        ],
        help=(
            "NWM configuration to run "
            f"(default: {NWMForecast.CONFIG_ANA})"
        ),
    )
    parser.add_argument(
        "--domain",
        default=NWMForecast.DOMAIN_CONUS,
        choices=[
            NWMForecast.DOMAIN_CONUS,
            NWMForecast.DOMAIN_HAWAII,
            NWMForecast.DOMAIN_ALASKA,
            NWMForecast.DOMAIN_PUERTO_RICO,
        ],
        help=(
            "NWM domain to run "
            f"(default: {NWMForecast.DOMAIN_CONUS})"
        ),
    )
    parser.add_argument(
        "--package-dir",
        required=True,
        help="Path to the NWM package directory",
    )
    parser.add_argument(
        "--working-dir",
        required=True,
        help="Path to the temporary working directory",
    )
    parser.add_argument(
        "--comout",
        required=True,
        help="Path to the COMOUT directory for reading/writing NWM output",
    )
    parser.add_argument(
        "--previous-day-comout",
        required=True,
        help="Path to the previous day's COMOUT directory, used when T0 - 3h rolls back to the prior day",
    )
    parser.add_argument(
        "--region-file",
        required=True,
        help=(
            "Path to a JSON file listing the VPU/basin regions to run. Each "
            "region provides its own hydrofabric, formulation-assignment, and "
            "catchment-group files (replaces --vpu/--hydrofab_file/"
            "--form-assign-file/--cat-grp-file)."
        ),
    )
    args = parser.parse_args()
    t0 = datetime.strptime(args.t0, "%Y-%m-%d %H:%M:%S")
    package_dir = args.package_dir
    working_dir = args.working_dir
    os.makedirs(working_dir, exist_ok=True)

    with open(args.region_file) as f:
        region_specs = json.load(f)["regions"]

    print(f"Config   : {args.config_name}")
    print(f"Domain   : {args.domain}")
    print(f"T0       : {t0}")
    print(f"Package  : {package_dir}")
    print(f"Work dir : {working_dir}")
    print(f"Regions  : {args.region_file} ({len(region_specs)} region(s))")

    # Build one forecast per region (VPU or single-gage basin) and collect them
    # into an NWMRunner keyed by region.

    # hardcode the cores for extended AnA because it runs at the same time
    # as the standarded AnA. A better algorithm is needed here to automatically
    # detect idling cores and assign the idling cores.
    ncores = os.cpu_count()
    runner = NWMRunner( cores = [ c for c in range( ncores - 1, 9, -1 ) ] 
                   if args.config_name == NWMForecast.CONFIG_EXT_ANA else None )

    for spec in region_specs:
        rtype = spec["type"].lower()
        is_vpu = rtype == "vpu"
        if rtype not in ("vpu", "basin"):
            raise ValueError(f"Unknown region type {spec['type']!r} in {args.region_file}")

        fcst = NWMForecast.create(
            config_name=args.config_name,
            domain=args.domain,
            t0=t0,
            package_dir=package_dir,
            working_dir=working_dir,
            comout=args.comout,
            previous_day_comout=args.previous_day_comout,
            vpu=spec["id"] if is_vpu else None,
            hydrofab_file=spec.get("hydrofabric"),
            form_assign_file=spec.get("formulation_assignment"),
            cat_grp_file=spec.get("catchment_group"),
            gageid=spec["id"] if not is_vpu else "01123000",
            nprocs=spec.get("nprocs", 2),
        )

        if is_vpu:
            region = VPU(
                id=spec["id"],
                case_type=fcst.case_type,
                hydrofabric=spec.get("hydrofabric"),
                formulation_assignment=spec.get("formulation_assignment"),
                catchment_group=spec.get("catchment_group"),
            )
        else:
            region = Basin(
                id=spec["id"],
                case_type=fcst.case_type,
                hydrofabric=spec.get("hydrofabric"),
            )
        runner.add(region, fcst)

    rc = runner.run()
    if rc != 0:
        print(f"ERROR: one or more NWM regions exited with return code {rc}", flush=True)
        sys.exit(rc)


if __name__ == "__main__":
    main()
