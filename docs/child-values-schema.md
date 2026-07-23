# child chart values 스키마

child가 `chart/values.schema.json`으로 **복사해 넣는** 정본이다. 이 문서가 정본이고,
Federation repository에 실행 가능한 파일로는 두지 않는다.

## 왜 전체가 아니라 일부만 검증하는가

Helm은 `values.schema.json`을 **최종 병합된 values**에 적용한다. 즉 child 기본값뿐 아니라
Federation이 얹는 `runtime-values.yaml`과 `values.yaml`까지 함께 검증 대상이 된다.

그래서 루트를 `additionalProperties: false`로 닫으면 **Federation이 주입하는 키를 child
스키마가 막아 버린다.** 실제로 그 상태에서 `runtime-values.yaml`에 `placement`를 넣으면
Argo가 렌더 단계에서 이렇게 실패한다.

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
- at '': additional properties 'placement' not allowed
```

따라서 이 스키마는 **플랫폼이 소유한 subtree(`images`)만 strict하게** 보고 나머지는 연다.
child 고유 values(`replicas`, `env`, 컨트롤러 설정 등)는 child가 알아서 할 일이지 계약이 아니다.

## 무엇을 검증하지 않는가

- **policy가 실제로 렌더되는지** — 스키마의 일이 아니다. 렌더 결과를 봐야 알 수 있다.
  workload와 `PropagationPolicy`의 1:1 대응, dangling selector, 금지 kind 같은 불변식은
  렌더 결과 검증에서 다룬다.
- **`tag`의 semver 여부** — Tekton `child-buildkit-build-push` Task의 `validate-targets`
  스텝 한 곳에서만 강제한다. 같은 규칙을 두 곳에 두면 드리프트한다. 또한 Federation의
  generated values는 `sha-<40hex>` 태그를 쓸 수 있으므로 스키마가 semver를 강제하면
  배포가 깨진다.

## `images`와 `karmada`를 required로 두지 않은 이유

- 서드파티 이미지만 쓰는 child(직접 빌드하는 이미지가 없는 경우)를 막지 않기 위해
- policy를 다르게 구성하는 child를 막지 않기 위해

## 정본

아래를 그대로 `chart/values.schema.json`으로 복사한다. 원격 `$ref`로 참조하지 않는다 —
Helm은 `$ref`의 URL을 실제로 HTTP fetch하므로, Argo repo-server와 Tekton이 렌더할 때마다
외부 네트워크에 의존하게 된다. (`$id`는 fetch 대상이 아니라 식별자일 뿐이다.)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://scalex.io/schemas/child-values/v1",
  "title": "ScaleX child chart values - platform contract",
  "description": "Federation이 소유하는 values subtree만 검증한다. child 고유 values는 검증하지 않는다. 정본은 scalex-federation/docs/child-values-schema.md 이며, child는 이 내용을 chart/values.schema.json으로 복사한다.",

  "type": "object",
  "additionalProperties": true,

  "properties": {
    "images": {
      "description": "이미지 인벤토리. key는 images/<name>/Dockerfile의 <name>과 같아야 한다. repository/tag는 child가, digest/sourceRevision은 Federation promotion이 주입한다.",
      "type": "object",
      "propertyNames": {
        "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$"
      },
      "additionalProperties": {
        "type": "object",
        "additionalProperties": false,
        "required": ["repository", "tag", "pullPolicy"],
        "properties": {
          "repository": {
            "type": "string",
            "pattern": "^[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+$"
          },
          "tag": {
            "description": "OCI tag. semver 강제는 Tekton child-buildkit-build-push Task가 한다. 두 곳에서 강제하면 규칙이 드리프트하고, Federation generated values가 sha-<40hex> 태그를 쓰는 경우 렌더가 깨진다.",
            "type": "string",
            "pattern": "^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$"
          },
          "pullPolicy": {
            "enum": ["Always", "IfNotPresent"]
          },
          "digest": {
            "description": "Federation promotion이 주입한다. child 기본값에는 없다.",
            "type": "string",
            "pattern": "^sha256:[0-9a-f]{64}$"
          },
          "sourceRevision": {
            "description": "Federation promotion이 주입한다. 40자 소문자 Git SHA.",
            "type": "string",
            "pattern": "^[0-9a-f]{40}$"
          }
        }
      }
    },

    "karmada": {
      "description": "Karmada policy 토글. Federation values에서는 반드시 enabled=true여야 한다. policy가 실제로 렌더되는지는 스키마가 아니라 렌더 결과 검증이 확인한다.",
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "enabled": {
          "type": "boolean"
        }
      }
    },

    "nameOverride": {
      "type": "string"
    },
    "fullnameOverride": {
      "type": "string"
    }
  }
}
```

## child 쪽 확인

```bash
# 1. 임의 runtime 키가 통과해야 한다 (Federation override 여지)
printf 'placement:\n  frontend:\n    cluster: b\n' > /tmp/rt.yaml
helm template <release-id> chart -f /tmp/rt.yaml >/dev/null

# 2. 계약 위반은 차단되어야 한다 (아래는 실패해야 정상)
helm template <release-id> chart --set images.<name>.pullPolicy=Never

# 3. 기본값만으로 lint가 통과해야 한다
helm lint --strict chart
```
