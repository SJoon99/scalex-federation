#!/usr/bin/env python3

from pathlib import Path
import re
import yaml

ROOT = Path(__file__).resolve().parents[1]
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
IMAGE_KEY = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def load(path: Path):
    with path.open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


applicationset = load(ROOT / "argocd/applicationset.yaml")
source = applicationset["spec"]["template"]["spec"]["sources"][0]
assert 'dig "source" "revision"' in source["targetRevision"]
assert 'dig "promotion" "resolvedRevision"' in source["targetRevision"]
assert "ignoreMissingValueFiles" not in source["helm"]
assert source["helm"]["valueFiles"] == [
    "$federation/releases/{{ .name }}/runtime-values.yaml",
    "$federation/{{ .values.path }}",
]

for release_path in sorted((ROOT / "releases").glob("*/release.yaml")):
    release = load(release_path)
    assert release_path.parent.name == release["name"]
    assert release["values"]["path"] == f"releases/{release['name']}/values.yaml"
    if release["state"] != "active":
        continue
    explicit = release["source"].get("revision")
    resolved = release.get("promotion", {}).get("resolvedRevision")
    effective = explicit or resolved
    assert effective and FULL_SHA.fullmatch(effective), release_path
    assert effective != "0" * 40, release_path
    assert (release_path.parent / "runtime-values.yaml").is_file(), release_path
    mode = release.get("promotion", {}).get("mode")
    if explicit:
        assert mode == "pinned", release_path
    else:
        assert mode == "tracking" and resolved, release_path

release_dir = ROOT / "releases/temp-poc"
temp_release = load(release_dir / "release.yaml")
runtime_values = load(release_dir / "runtime-values.yaml")
generated_values = load(release_dir / "values.yaml")
assert "revision" not in temp_release["source"]
assert temp_release["promotion"]["mode"] == "tracking"
assert FULL_SHA.fullmatch(temp_release["promotion"]["resolvedRevision"])
assert runtime_values == {}
assert "images" not in runtime_values
assert set(generated_values) == {"images"}
for key, image in generated_values["images"].items():
    assert IMAGE_KEY.fullmatch(key)
    assert FULL_SHA.fullmatch(image["sourceRevision"])
    assert DIGEST.fullmatch(image["digest"])
    assert image["pullPolicy"] in {"Always", "IfNotPresent"}
print("ScaleX Federation promotion contract: PASS")
