"""Print one line per dataset (<model> <name> <shape> <chunks>) and per component axis
(<model> axis <key> labels <shape> ids <shape>). Each optional <path> <i,j,...> pair after
the directory prints "value <path> <i,j,...> <value>". Uses json + h5py."""
import json
import sys

import h5py


def main(directory, points):
    try:
        with open(f"{directory}/outputs.json") as fh:
            meta = json.load(fh)
        models = meta["models"]
    except (OSError, ValueError, KeyError, TypeError) as err:
        print(f"cannot parse {directory}/outputs.json: {err}", file=sys.stderr)
        sys.exit(2)
    with h5py.File(f"{directory}/outputs.h5", "r") as h5:
        for spec in models:
            model = spec["name"]
            for entry in spec["datasets"]:
                path = entry["path"]
                if path not in h5:
                    print(f"missing dataset {path}", file=sys.stderr)
                    sys.exit(2)
                ds = h5[path]
                print(model, path.rsplit("/", 1)[-1], ds.shape, ds.chunks)
            for axis in spec["axes"]:
                if axis["kind"] != "component":
                    continue
                key = axis["group"].rsplit("/", 1)[-1]
                group = h5[axis["group"]]
                ids = group["ids"].shape if "ids" in group else "none"
                print(model, "axis", key, "labels", group["labels"].shape, "ids", ids)
        for path, index in points:
            idx = tuple(int(i) for i in index.split(","))
            print("value", path, index, float(h5[path][idx]))


if __name__ == "__main__":
    if len(sys.argv) < 2 or len(sys.argv) % 2 != 0:
        sys.exit("usage: read_outputs.py <dir> [<path> <i,j,...>]...")
    main(sys.argv[1], list(zip(sys.argv[2::2], sys.argv[3::2])))
