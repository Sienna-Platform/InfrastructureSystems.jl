"""Print one line per dataset (<model> <name> <shape> <chunks>) and per component axis
(<model> axis <key> labels <shape> ids <shape>). With --schema <dir>, also validate
outputs.json against OutputsDocument.json in <dir> (exit 3 on failure, else print
"schema ok"). Uses json + h5py, plus jsonschema for --schema."""
import json
import pathlib
import sys

import h5py


def validate_schema(meta, schema_dir):
    from jsonschema import Draft202012Validator
    from referencing import Registry, Resource
    from referencing.jsonschema import DRAFT202012

    registry = Registry()
    for path in pathlib.Path(schema_dir).glob("*.json"):
        resource = Resource.from_contents(
            json.loads(path.read_text()), default_specification=DRAFT202012
        )
        registry = registry.with_resource(path.name, resource)
    root = json.loads((pathlib.Path(schema_dir) / "OutputsDocument.json").read_text())
    errors = list(Draft202012Validator(root, registry=registry).iter_errors(meta))
    for err in errors:
        print(f"schema error {list(err.absolute_path)}: {err.message[:200]}", file=sys.stderr)
    if errors:
        sys.exit(3)
    print("schema ok")


def main(directory, schema_dir):
    try:
        with open(f"{directory}/outputs.json") as fh:
            meta = json.load(fh)
        models = meta["models"]
    except (OSError, ValueError, KeyError, TypeError) as err:
        print(f"cannot parse {directory}/outputs.json: {err}", file=sys.stderr)
        sys.exit(2)
    if schema_dir is not None:
        validate_schema(meta, schema_dir)
    with h5py.File(f"{directory}/outputs.h5", "r") as h5:
        for model, spec in models.items():
            for entry in spec["datasets"]:
                path = entry["path"]
                if path not in h5:
                    print(f"missing dataset {path}", file=sys.stderr)
                    sys.exit(2)
                ds = h5[path]
                print(model, path.rsplit("/", 1)[-1], ds.shape, ds.chunks)
            for key, axis in spec["axes"].items():
                if axis["kind"] != "component":
                    continue
                group = h5[axis["group"]]
                ids = group["ids"].shape if "ids" in group else "none"
                print(model, "axis", key, "labels", group["labels"].shape, "ids", ids)


if __name__ == "__main__":
    args = sys.argv[1:]
    schema = None
    if len(args) == 3 and args[1] == "--schema":
        schema = args[2]
        args = args[:1]
    if len(args) != 1:
        sys.exit("usage: read_outputs.py <dir> [--schema <schema-dir>]")
    main(args[0], schema)
