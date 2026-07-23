#!/usr/bin/env python3
"""ScaleX Federation promotion contract.

release 개수나 이름에 의존하지 않는다. `releases/*/release.yaml`을 전부 순회하며
같은 계약을 적용하므로 child가 추가/삭제되어도 테스트가 따라간다.
"""

from pathlib import Path
import re
import sys
import yaml

ROOT = Path(__file__).resolve().parents[1]
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
IMAGE_KEY = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ZERO_SHA = "0" * 40

# AppProject destination이 scalex-* namespace만 허용한다.
NAMESPACE_PREFIX = "scalex-"

VALID_STATES = {"active", "disabled"}
VALID_MODES = {"pinned", "tracking"}

# 어떤 child도 요구 선언 없이 쓸 수 있는 기본 kind. 이 밖의 kind가 AppProject에 열려
# 있다면 어떤 release의 requiredKinds가 그것을 요구해서 열린 것이어야 한다.
BASE_KINDS = {
    # cluster-scoped
    "Namespace", "ClusterResourceBinding",
    # namespaced
    "ConfigMap", "ServiceAccount", "Service",
    "Deployment", "StatefulSet", "DaemonSet",
    "Job", "CronJob", "HorizontalPodAutoscaler",
    "Role", "RoleBinding",
    "PropagationPolicy", "OverridePolicy", "ResourceBinding",
}

failures = []
warnings = []


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def warn(condition, message):
    if not condition:
        warnings.append(message)
    return condition


def load(path: Path):
    with path.open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def load_mapping(path: Path):
    """빈 파일과 `{}`를 모두 빈 매핑으로 취급한다."""
    return load(path) or {}


# --------------------------------------------------------------- ApplicationSet

applicationset = load(ROOT / "argocd/applicationset.yaml")
source = applicationset["spec"]["template"]["spec"]["sources"][0]
check('dig "source" "revision"' in source["targetRevision"],
      "applicationset: source.revision 우선 규칙이 사라졌다")
check('dig "promotion" "resolvedRevision"' in source["targetRevision"],
      "applicationset: promotion.resolvedRevision fallback이 사라졌다")
check("ignoreMissingValueFiles" not in source["helm"],
      "applicationset: ignoreMissingValueFiles는 values 누락을 숨긴다")
check(source["helm"]["valueFiles"] == [
          "$federation/releases/{{ .name }}/runtime-values.yaml",
          "$federation/{{ .values.path }}",
      ],
      "applicationset: values 적용 순서가 runtime → generated가 아니다")

selector = applicationset["spec"]["generators"][0]["selector"]["matchLabels"]
check(selector.get("state") == "active",
      "applicationset: state=active selector가 사라졌다")

# --------------------------------------------------------------- release 순회

appproject = load(ROOT / "argocd/appproject.yaml")
allowed_kinds = {
    entry["kind"]
    for key in ("clusterResourceWhitelist", "namespaceResourceWhitelist")
    for entry in appproject["spec"].get(key) or []
}

release_paths = sorted((ROOT / "releases").glob("*/release.yaml"))
check(bool(release_paths), "releases/*/release.yaml 이 하나도 없다")

active_count = 0
claimed_kinds = set()

for release_path in release_paths:
    rel = release_path.parent.name
    release = load(release_path)

    # --- 모든 release에 적용되는 계약 ---------------------------------------

    check(rel == release.get("name"),
          f"{rel}: 디렉터리명과 release.yaml의 name이 다르다 ({release.get('name')})")
    check(release.get("values", {}).get("path") == f"releases/{release.get('name')}/values.yaml",
          f"{rel}: values.path가 자기 디렉터리를 가리키지 않는다")

    namespace = release.get("namespace", "")
    check(namespace.startswith(NAMESPACE_PREFIX),
          f"{rel}: namespace가 '{NAMESPACE_PREFIX}'로 시작하지 않는다 "
          f"({namespace}) — AppProject destination이 거부한다")

    state = release.get("state")
    check(state in VALID_STATES, f"{rel}: 알 수 없는 state ({state})")

    mode = release.get("promotion", {}).get("mode")
    check(mode in VALID_MODES, f"{rel}: 알 수 없는 promotion.mode ({mode})")

    # requiredKinds: BASE_KINDS 밖의 kind를 chart가 렌더한다면 여기에 선언한다.
    # 선언은 AppProject 확장의 사유를 PR diff에 남기기 위한 것이다.
    required_kinds = release.get("requiredKinds") or []
    if check(isinstance(required_kinds, list), f"{rel}: requiredKinds는 리스트여야 한다"):
        for kind in required_kinds:
            claimed_kinds.add(kind)
            check(kind in allowed_kinds,
                  f"{rel}: requiredKinds의 {kind}가 AppProject whitelist에 없다 "
                  f"(Argo가 sync 시점에 거부한다)")
            warn(kind not in BASE_KINDS,
                 f"{rel}: requiredKinds의 {kind}는 기본 허용 kind다. 선언할 필요가 없다")

    explicit = release.get("source", {}).get("revision")
    if explicit is not None:
        check(mode == "pinned",
              f"{rel}: source.revision이 있으면 mode는 pinned여야 한다 (현재 {mode})")
    elif mode == "pinned":
        failures.append(f"{rel}: mode가 pinned인데 source.revision이 없다")
    # mode == tracking 이고 source.revision이 없는 것은 정상이다.
    # 첫 promote가 promotion.resolvedRevision을 써 넣는다.

    if state != "active":
        continue

    # --- active release에만 적용되는 계약 -----------------------------------

    active_count += 1
    resolved = release.get("promotion", {}).get("resolvedRevision")
    effective = explicit or resolved

    if check(bool(effective), f"{rel}: active인데 effective revision이 없다"):
        check(bool(FULL_SHA.fullmatch(str(effective))),
              f"{rel}: effective revision이 40자 소문자 SHA가 아니다 ({effective})")
        check(effective != ZERO_SHA, f"{rel}: effective revision이 all-zero 플레이스홀더다")

    if mode == "tracking":
        check(explicit is None, f"{rel}: tracking인데 source.revision이 있다")
        check(bool(resolved),
              f"{rel}: tracking active인데 promotion.resolvedRevision이 없다")

    runtime_path = release_path.parent / "runtime-values.yaml"
    values_path = release_path.parent / "values.yaml"

    if not check(runtime_path.is_file(),
                 f"{rel}: runtime-values.yaml이 없다 "
                 f"(promote의 render-candidate가 'promotion values missing'으로 실패한다)"):
        continue
    if not check(values_path.is_file(), f"{rel}: values.yaml이 없다"):
        continue

    runtime_values = load_mapping(runtime_path)
    generated_values = load_mapping(values_path)

    check("images" not in runtime_values,
          f"{rel}: runtime-values.yaml이 images를 갖고 있다 "
          f"(image identity는 promote가 소유한다)")

    if not check(set(generated_values) == {"images"},
                 f"{rel}: values.yaml은 images만 가져야 한다 "
                 f"(현재 {sorted(generated_values) or '비어 있음'})"):
        continue

    images = generated_values["images"]
    if not check(isinstance(images, dict) and bool(images),
                 f"{rel}: values.yaml의 images가 비어 있다"):
        continue

    for key, image in images.items():
        check(bool(IMAGE_KEY.fullmatch(key)),
              f"{rel}: image key가 kebab-case가 아니다 ({key})")
        check(bool(FULL_SHA.fullmatch(str(image.get("sourceRevision", "")))),
              f"{rel}/{key}: sourceRevision이 40자 SHA가 아니다")
        check(bool(DIGEST.fullmatch(str(image.get("digest", "")))),
              f"{rel}/{key}: digest가 sha256:<64hex>가 아니다")
        check(image.get("pullPolicy") in {"Always", "IfNotPresent"},
              f"{rel}/{key}: pullPolicy가 Always|IfNotPresent가 아니다")
        check(bool(image.get("repository")), f"{rel}/{key}: repository가 없다")
        check(bool(image.get("tag")), f"{rel}/{key}: tag가 없다")

    # chart revision과 image가 같은 커밋에서 왔는지.
    if effective:
        mismatched = sorted(
            key for key, image in images.items()
            if image.get("sourceRevision") != effective
        )
        check(not mismatched,
              f"{rel}: image sourceRevision이 effective revision과 다르다 ({', '.join(mismatched)})")

# ------------------------------------------------- AppProject 권한 회계 (T6)

# 아무 release도 요구하지 않는데 열려 있는 권한. offboarding 잔여물이거나
# 선제 개방이다. 보안 경계가 조용히 넓어지지 않도록 드러낸다.
unclaimed = sorted(allowed_kinds - BASE_KINDS - claimed_kinds)
warn(not unclaimed,
     f"AppProject가 허용하지만 어떤 release도 requiredKinds로 요구하지 않는 kind: "
     f"{', '.join(unclaimed)}")

# --------------------------------------------------------------- 결과

total = len(release_paths)
status = "FAIL" if failures else "PASS"
print(f"ScaleX Federation promotion contract: {status} "
      f"(releases={total} active={active_count} "
      f"failures={len(failures)} warnings={len(warnings)})")
for message in failures:
    print(f"  [FAIL] {message}")
for message in warnings:
    print(f"  [WARN] {message}")
sys.exit(1 if failures else 0)
