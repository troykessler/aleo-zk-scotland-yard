"""Print a Leo Merkle root for every maps/*.csv, or for the paths given."""

import argparse
import csv
import json
from pathlib import Path
import subprocess
import tempfile


MAPS = Path(__file__).resolve().parents[1] / "maps"
MAP_MERKLE_ROOT_DEPTH = 9
LEAF_COUNT = 1 << MAP_MERKLE_ROOT_DEPTH


def read_edges(path):
    edges = {}
    with path.open(encoding="utf-8-sig", newline="") as stream:
        rows = csv.reader(stream, strict=True)
        if next(rows, None) != ["low", "high", "mode_mask"]:
            raise ValueError("expected header low,high,mode_mask")
        for row in rows:
            try:
                low, high, mask = map(int, row)
            except ValueError:
                raise ValueError(f"line {rows.line_num}: expected three integers") from None
            if not (0 <= low < high <= 255 and 1 <= mask <= 255):
                raise ValueError(f"line {rows.line_num}: expected ordered u8 endpoints and a nonzero u8 mask")
            if (low, high) in edges:
                raise ValueError(f"line {rows.line_num}: duplicate edge {low},{high}")
            edges[low, high] = mask
    if not edges:
        raise ValueError("map contains no edges")
    return [(low, high, edges[low, high]) for low, high in sorted(edges)]


def leo_source(edges):
    """Hash typed u8 triples, right-pad with empty edges, then hash ordered field pairs."""
    if len(edges) > LEAF_COUNT:
        raise ValueError(f"map contains {len(edges)} edges; maximum is {LEAF_COUNT}")
    lines = ["program map_root.aleo {", "@noupgrade constructor() {}", "fn root() -> field {"]
    nodes = []
    for i, (low, high, mask) in enumerate(edges):
        name = f"leaf_{i}"
        lines.append(f"let {name} = Poseidon4::hash_to_field([{low}u8, {high}u8, {mask}u8]);")
        nodes.append(name)
    if len(nodes) < LEAF_COUNT:
        lines.append("let empty = Poseidon4::hash_to_field([0u8, 0u8, 0u8]);")
        nodes.extend(["empty"] * (LEAF_COUNT - len(nodes)))

    level = 0
    while len(nodes) > 1:
        parents = []
        for i in range(0, len(nodes), 2):
            parent = f"node_{level}_{i // 2}"
            lines.append(f"let {parent} = Poseidon4::hash_to_field([{nodes[i]}, {nodes[i + 1]}]);")
            parents.append(parent)
        nodes = parents
        level += 1
    return "\n".join([*lines, f"return {nodes[0]};", "}", "}"])


def map_root(path):
    source = leo_source(read_edges(path))
    with tempfile.TemporaryDirectory() as directory:
        project = Path(directory)
        (project / "src").mkdir()
        (project / "src/main.leo").write_text(source, encoding="utf-8")
        (project / "program.json").write_text(json.dumps({
            "program": "map_root.aleo", "version": "0.1.0", "leo": "4.4.6",
            "description": "", "license": "MIT", "dependencies": None,
        }), encoding="utf-8")
        result = subprocess.run(
            ["leo", "run", "root", "--offline", "--json-output=result.json"],
            cwd=project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        if result.returncode:
            raise ValueError(result.stdout.strip())
        return json.loads((project / "result.json").read_text())["outputs"][0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("maps", nargs="*", type=Path, metavar="CSV")
    paths = parser.parse_args().maps or sorted(MAPS.glob("*.csv"))
    if not paths:
        parser.exit(1, f"No map CSVs in {MAPS}\n")
    for path in paths:
        try:
            print(f"{path.name}\t{map_root(path)}")
        except (OSError, csv.Error, ValueError) as error:
            parser.exit(1, f"{path}: {error}\n")
