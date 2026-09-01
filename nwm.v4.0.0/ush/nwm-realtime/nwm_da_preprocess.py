import argparse
import os
import sys

from da_preprocessor import DAPreprocessor


def main():
    parser = argparse.ArgumentParser(
        description="Pre-process observed streamflow/reservoir data into NWM "
                    "timeslice and timeseries files"
    )
    parser.add_argument(
        "--case-type",
        required=True,
        choices=list(DAPreprocessor.CASE_TYPES),
        help=(
            "Observation source to pre-process. "
            f"{DAPreprocessor.CASE_USGS_N_ENVCA} covers USGS and Env. Canada "
            "together, including the merge of their timeslices."
        ),
    )
    parser.add_argument(
        "--pdy",
        required=True,
        metavar="YYYYMMDD",
        help="Date of the current cycle, e.g. 20260721",
    )
    parser.add_argument(
        "--cyc",
        required=True,
        metavar="HH",
        help="Current cycle, 00 to 23",
    )
    parser.add_argument(
        "--package-dir",
        required=True,
        help="Path to the NWM package directory (holds ush/nwm-data-assimilation)",
    )
    parser.add_argument(
        "--working-dir",
        required=True,
        help="Path to the temporary working directory",
    )
    parser.add_argument(
        "--comout",
        required=True,
        help="Path to the COMOUT directory the products are stored in",
    )
    parser.add_argument(
        "--precomout",
        required=True,
        help=(
            "Path to the previous day's COMOUT directory, used once the lookback "
            "window reaches back across midnight"
        ),
    )
    parser.add_argument(
        "--dcomroot",
        required=True,
        help="Path to the DCOM root holding the raw downloaded observations",
    )
    args = parser.parse_args()

    os.makedirs(args.working_dir, exist_ok=True)

    print(f"Case type : {args.case_type}")
    print(f"PDY/CYC   : {args.pdy} {args.cyc}z")
    print(f"Package   : {args.package_dir}")
    print(f"Work dir  : {args.working_dir}")
    print(f"COMOUT    : {args.comout}")
    print(f"PRECOMOUT : {args.precomout}")
    print(f"DCOMROOT  : {args.dcomroot}")

    preprocessor = DAPreprocessor.create(
        case_type=args.case_type,
        pdy=args.pdy,
        cyc=args.cyc,
        working_dir=args.working_dir,
        comout=args.comout,
        precomout=args.precomout,
        dcomroot=args.dcomroot,
        package_dir=args.package_dir,
    )

    rc = preprocessor.run()
    if rc != 0:
        print(f"ERROR: {args.case_type} pre-processing exited with return code {rc}",
              flush=True)
        sys.exit(rc)


if __name__ == "__main__":
    main()
