# child 온보딩 runbook — 풀 CI 경로

임의의 child repository를 `scalex-federation`에 붙여 member cluster에 배포하기까지의
**실행형 절차**다. 자체 `images/<image>/Dockerfile`을 빌드해 Tekton `child-build`(파생 T8 ·
자동 promote T10)를 전 구간 통과시킨다.

아래 **결정할 값**을 자기 것으로 치환해 따라 하면 된다. 이 문서의 파일·명령 예시는
worked example인 **sample-poc**(기능 `scalex-return-feature`, member `c`)를 그대로 쓰므로,
복사한 뒤 이름만 바꾸면 된다. 개념 배경은
[`child-onboarding-runbook.md`](child-onboarding-runbook.md) · `dev/명세/*.md` 참고.
각 단계에 관찰 지점(👀)과 판단 지점(🧑‍⚖️)을 표시했다.

---

## 결정할 값 (먼저 정한다)

| placeholder | 뜻 | worked example (sample-poc) |
|---|---|---|
| `<owner>/<child>` | child GitHub repo | `BellTigerLee/sample-poc` |
| `<child>` | release·namespace 베이스 이름 | `sample-poc` |
| release ID = namespace | **반드시 `scalex-*`** (AppProject 제약) | `scalex-sample-poc` |
| `<feature>` | `templates/` 밑 기능 폴더명 | `scalex-return-feature` |
| `<member>` | 배포 대상 member cluster | `c` |
| `<image>` | 빌드 이미지 논리 이름 (`images/<image>/Dockerfile`) | `app` |
| image 경로 | `<registry>/<prefix>/<child>/<image>` | `10.34.25.18/tower-ci/sample-poc/app` |
| image tag | 반드시 `vX.Y.Z` | `v0.1.0` |
| chart path | Federation이 읽는 경로 (고정) | `chart` |

> **치환 규칙**: 이 아래 S1~S3의 명령·파일은 sample-poc 예시 그대로다. 자기 child를 만들 땐
> `sample-poc`→`<child>`, `scalex-return-feature`→`<feature>`, `c`→`<member>`, repo URL을
> 자기 것으로 바꾼다. **release 디렉터리명·`release.yaml`의 name·namespace·source repo 이름은
> 서로 일치**시키고, namespace는 `scalex-` 접두사를 쓴다.

federation 로컬 경로 예시: `/home/work8/netai/dev/scalex-federation`

---

## 진행 체크리스트

- [ ] S0. 사전 확인 (member c 등록, tower-ci 접근, Harbor/GitHub secret)
- [ ] S1. child repository 채우기 (manifests + src + Dockerfile → helm create → chart 적응)
- [ ] S2. 로컬 검증 (helm lint/template + 계약 + docker build)
- [ ] S3. commit + push → child SHA 기록
- [ ] S4. Federation PR① — AppProject sourceRepos에 sample-poc 추가
- [ ] S5. Federation PR② — disabled release 등록 (release.yaml + runtime-values.yaml)
- [ ] S6. Tekton child-build PipelineRun 1회 제출 → promotion PR 생성 관찰
- [ ] S7. promotion PR 검토 + merge
- [ ] S8. Federation PR③ — state: active
- [ ] S9. 배포 확인 (Argo → Karmada → member c pod)
- [ ] S10. 정지 / rollback / offboard (참고)

---

## S0. 사전 확인

우리가 만들지 않고 **이미 있어야 하는** 것들. 없으면 여기서 멈추고 운영자에게 요청한다.

```bash
# tower control plane 접근 (PipelineRun을 여기에 제출한다)
tkubectl get ns tower-ci

# Karmada에 member c가 등록되어 있는지 (placement 대상)
tkubectl -n karmada-system get clusters.cluster.karmada.io
#   → 목록에 'c'가 Ready 로 보여야 한다

# Harbor 빌더 자격증명과 GitHub App secret (bootstrap 경계)
tkubectl -n tower-ci get secret harbor-builder federation-promotion-github-app
```

🧑‍⚖️ **판단**: member `c`가 안 보이면, member 등록은 tower-k8s/`*-k8s` 경로의 별도 작업이다.
그 경우 잠깐 멈추고 정한다 (다른 member로 바꿀지, 등록을 먼저 할지).

> 참고: 현재 push→PipelineRun 자동 트리거(EventListener)는 별도 repo 소유이며 없을 수 있다.
> S6에서 PipelineRun은 **수동 제출**한다. 단, S3 push 직후 자동으로 뜨는지 먼저 관찰한다.

---

## S1. child repository 채우기 (plain 매니페스트 → `helm create` → 적응)
<!-- 아래는 worked example(sample-poc). 자기 child는 결정한 값으로 치환한다. -->


**핵심 원칙: 사람은 gotemplate을 손으로 쓰지 않는다.** 평범한 k8s 매니페스트를 작성하고,
`helm create`로 chart 골격을 만든 뒤 소수 지점만 적응한다.

최종 레이아웃:
```text
sample-poc/
├── manifests/          # 사람이 쓰는 진실의 원천 (순수 k8s YAML)
│   ├── deployment.yaml
│   └── service.yaml
├── src/app.py          # beacon 앱
├── images/app/Dockerfile
└── chart/              # helm create → 적응한 배포물 (커밋됨, 만지지 않음)
    ├── Chart.yaml
    ├── values.yaml
    ├── values.schema.json
    └── templates/
        ├── _helpers.tpl
        ├── scalex-return-feature/          # 기능명 폴더 → workload를 담음
        │   ├── deployment.yaml
        │   └── service.yaml
        └── policy/
            ├── propagation/
            │   └── scalex-return-feature.yaml
            └── overrides/               # OverridePolicy가 생기면 여기에. 지금은 비어 있음
                └── .gitkeep
```

> **templates 하위 구조 규칙** (temp-poc와 동일): workload는 `templates/<기능명>/`에,
> 정책은 `templates/policy/{propagation,overrides}/`에 분리해서 넣는다. 기능이 여러 개면
> 기능명 폴더를 여러 개 만든다. 지금은 `PropagationPolicy`만 있으므로 `propagation/`에만
> yaml을 두고 `overrides/`는 빈 폴더로 둔다(`.gitkeep`로 유지, `.helmignore`에 등록해 helm이
> 무시하게 한다). member별 필드 변경(Service→LoadBalancer 등)이 실제로 필요할 때
> `overrides/`에 yaml이 생긴다.

> `manifests/`는 개발자가 편집하는 원본이고 `chart/`는 그로부터 만든 배포물이다. 지금은
> 손으로 적응하지만, `chart/`가 `manifests/`와 어긋나지 않게 하는 자동 생성기(drift 검사)는
> 후속 과제다. Argo는 child의 `chart/`를 pinned SHA에서 직접 렌더하므로 chart는 반드시
> repo에 물리적으로 존재해야 한다.

### 1) 앱 소스 `src/app.py`

pod/node 정체를 되돌려주는 stdlib-only HTTP beacon (배치 결과를 눈으로 증명하기 위함).
```python
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8080


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, content_type="application/json"):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, "ok\n", "text/plain")
            return
        beacon = {
            "app": "sample-poc",
            "pod": os.environ.get("POD_NAME", socket.gethostname()),
            "node": os.environ.get("NODE_NAME", "unknown"),
            "time": datetime.now(timezone.utc).isoformat(),
        }
        self._send(200, json.dumps(beacon) + "\n")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
```

### 2) 빌드 레시피 `images/app/Dockerfile`
```dockerfile
# Build context is the repository root (Tekton derive-targets sets context ".").
FROM python:3.13-alpine
COPY src/app.py /app/app.py
USER 65532:65532
EXPOSE 8080
ENV PYTHONDONTWRITEBYTECODE=1
ENTRYPOINT ["python", "/app/app.py"]
```
> context는 repo root(`.`), dockerfile은 `images/app/Dockerfile` — Tekton T8 파생과 동일.
> 그래서 `COPY src/app.py`가 동작한다.

### 3) plain 매니페스트 `manifests/`

진짜 `kubectl apply` 가능한 형태. **이미지는 전체 경로로 쓴다**(생성기가 Harbor 경로 규칙을
몰라도 되게). 이게 chart 적응의 원본이다.

`manifests/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-poc
  labels:
    app: sample-poc
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-poc
  template:
    metadata:
      labels:
        app: sample-poc
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: 10.34.25.18/tower-ci/sample-poc/app:v0.1.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
          readinessProbe: { httpGet: { path: /healthz, port: http } }
          livenessProbe:  { httpGet: { path: /healthz, port: http } }
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

`manifests/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: sample-poc
  labels:
    app: sample-poc
spec:
  type: ClusterIP
  selector:
    app: sample-poc
  ports:
    - name: http
      port: 80
      targetPort: http
```

### 4) `helm create`로 chart 골격 생성
```bash
cd /home/work8/netai/dev/sample-poc
helm create chart          # name=chart, 표준 골격 (ingress/hpa/httproute/sa/tests 포함)
```
> `helm create`의 결과물은 gotemplate로 가득하고 ScaleX엔 안 맞는다(PropagationPolicy 없음,
> `.Values.image` 단수, 금지 리소스 포함). 그래서 **골격으로만** 쓰고 아래처럼 적응한다.

### 5) 적응 — 삭제 + 폴더 구조 + 스키마 vendoring
```bash
cd /home/work8/netai/dev/sample-poc/chart
# a. helm create가 만든 불필요한 것 삭제
rm -f templates/hpa.yaml templates/httproute.yaml templates/ingress.yaml \
      templates/serviceaccount.yaml templates/NOTES.txt
rm -rf templates/tests
# b. 기능/정책 폴더 구조 생성 (temp-poc 규칙)
mkdir -p templates/scalex-return-feature templates/policy/propagation templates/policy/overrides
: > templates/policy/overrides/.gitkeep          # 빈 overrides 폴더 유지
# c. helm이 .gitkeep을 lint하지 않도록 .helmignore에 등록
printf '\n.gitkeep\n' >> .helmignore
# d. 스키마 vendoring (helm create는 안 만듦)
cp /home/work8/netai/dev/temp-poc/chart/values.schema.json ./values.schema.json
```
> helm create가 만든 `templates/deployment.yaml`·`service.yaml`은 아래 6)에서 각각
> `templates/scalex-return-feature/` 밑으로 옮기며 내용을 교체한다. `PropagationPolicy`는
> `templates/policy/propagation/scalex-return-feature.yaml`로 신규 작성한다.

### 6) 적응 — 파일 내용 교체

**`chart/Chart.yaml`** (helm create는 `name: chart`로 만듦 → `sample-poc`로):
```yaml
apiVersion: v2
name: sample-poc
description: ScaleX Federation child - identity beacon on a Karmada member cluster
type: application
version: 0.1.0
appVersion: "0.1.0"
```

**`chart/templates/_helpers.tpl`** (helper prefix `chart.*` → `sample-poc.*`, image helper 추가,
serviceAccount helper 삭제):
```gotemplate
{{- define "sample-poc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sample-poc.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "sample-poc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sample-poc.labels" -}}
helm.sh/chart: {{ include "sample-poc.chart" . }}
{{ include "sample-poc.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sample-poc
{{- end }}

{{- define "sample-poc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sample-poc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sample-poc.image" -}}
{{- if .digest -}}
{{- printf "%s:%s@%s" .repository .tag .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end }}
```

**`chart/templates/scalex-return-feature/deployment.yaml`** = `manifests/deployment.yaml`을 적응. **2군데만 치환**한다
— `name`/labels/selector는 helper로, `namespace`는 `.Release.Namespace`, `image`는
`.Values.images.app`(federation이 digest 주입):
```gotemplate
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "sample-poc.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "sample-poc.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.app.replicas }}
  selector:
    matchLabels:
      {{- include "sample-poc.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "sample-poc.selectorLabels" . | nindent 8 }}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: {{ include "sample-poc.image" (index .Values.images "app") | quote }}
          imagePullPolicy: {{ (index .Values.images "app").pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.app.port }}
          env:
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
          readinessProbe: { httpGet: { path: /healthz, port: http } }
          livenessProbe:  { httpGet: { path: /healthz, port: http } }
          resources:
            {{- toYaml .Values.app.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
```

**`chart/templates/scalex-return-feature/service.yaml`** = `manifests/service.yaml` 적응:
```gotemplate
apiVersion: v1
kind: Service
metadata:
  name: {{ include "sample-poc.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "sample-poc.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "sample-poc.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
```

**`chart/templates/policy/propagation/scalex-return-feature.yaml`** = **신규** (helm은 Karmada를 모름). workload+Service를
선택하고 배치 cluster는 values에서:
```gotemplate
{{- if .Values.karmada.enabled }}
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  name: {{ include "sample-poc.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "sample-poc.labels" . | nindent 4 }}
spec:
  conflictResolution: Abort
  preemption: Never
  propagateDeps: true
  resourceSelectors:
    - apiVersion: apps/v1
      kind: Deployment
      name: {{ include "sample-poc.fullname" . }}
      namespace: {{ .Release.Namespace }}
    - apiVersion: v1
      kind: Service
      name: {{ include "sample-poc.fullname" . }}
      namespace: {{ .Release.Namespace }}
  placement:
    clusterAffinity:
      clusterNames:
        - {{ required "karmada.placement.cluster is required" .Values.karmada.placement.cluster }}
    spreadConstraints:
      - spreadByField: cluster
        minGroups: 1
        maxGroups: 1
{{- end }}
```

**`chart/values.yaml`**:
```yaml
nameOverride: ""
fullnameOverride: ""

# Image inventory. Keys must match images/<name>/Dockerfile.
# repository/tag are child-owned; digest/sourceRevision are injected by Federation.
images:
  app:
    repository: 10.34.25.18/tower-ci/sample-poc/app
    tag: v0.1.0
    pullPolicy: IfNotPresent

app:
  replicas: 1
  port: 8080
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { cpu: 100m, memory: 64Mi }

service:
  type: ClusterIP
  port: 80

karmada:
  enabled: true
  placement:
    # 첫 테스트는 self-contained하게 child 기본값에 c를 둔다. multi-tenant에서는
    # Federation runtime-values.yaml이 채우는 것이 P5 설계상 정본.
    cluster: c
```

---

## S2. 로컬 검증

### a. helm lint + federation처럼 render
```bash
cd /home/work8/netai/dev/sample-poc
helm lint --strict chart
helm template scalex-sample-poc chart --namespace scalex-sample-poc > /tmp/sp.yaml
```

### b. 계약 불변식 (이름 무관)
```bash
python3 - <<'PY'
import yaml
docs=[d for d in yaml.safe_load_all(open('/tmp/sp.yaml')) if d]
kinds={}
for d in docs: kinds.setdefault(d['kind'],[]).append(d)
forbidden={'Namespace','Secret','ClusterRole','ClusterRoleBinding',
           'ClusterPropagationPolicy','ClusterOverridePolicy','Ingress'}
assert not (forbidden & set(kinds)), forbidden & set(kinds)
for d in docs:
    assert d['metadata']['namespace']=='scalex-sample-poc', d['kind']
dep=kinds['Deployment'][0]['metadata']['name']
svc=kinds['Service'][0]['metadata']['name']
pp=kinds['PropagationPolicy'][0]
sel=[(s['kind'],s['name']) for s in pp['spec']['resourceSelectors']]
assert ('Deployment',dep) in sel and ('Service',svc) in sel
assert pp['spec']['placement']['clusterAffinity']['clusterNames']==['c']
print("CONTRACT OK — kinds:", {k:len(v) for k,v in kinds.items()})
PY
```

### c. karmada.enabled=false 면 정책이 사라져야 한다 (로컬 설치 지원)
```bash
helm template scalex-sample-poc chart --namespace scalex-sample-poc \
  --set karmada.enabled=false | grep -c '^kind: PropagationPolicy'   # → 0
```

### d. 이미지 빌드 리허설 (S6 전 de-risk, docker 있으면)
```bash
docker build -f images/app/Dockerfile -t sample-poc-app:test .
docker run -d --rm --read-only --tmpfs /tmp \
  -e POD_NAME=probe -e NODE_NAME=fake-c -p 18080:8080 sample-poc-app:test
curl -s localhost:18080/healthz   # → ok
curl -s localhost:18080/          # → {"app":"sample-poc","pod":"probe","node":"fake-c",...}
```

👀 통과 기준: lint 0 failed · `CONTRACT OK`(kinds = Deployment/Service/PropagationPolicy 각 1) ·
policy count 0 · beacon이 `/`에서 JSON 응답.

🧑‍⚖️ digest는 아직 없다. 로컬 render의 image는 `...:v0.1.0`(digest 없음)이다. digest는
Tekton이 S6에서 주입한다. 정상이다.

> **실측 (2026-07-23)**: 위 4개 전부 통과. helm lint 0 failed, 계약 OK(3 kind),
> policy toggle 0, docker 이미지가 read-only rootfs·non-root로 구동되어 두 엔드포인트 정상.

---

## S3. commit + push

```bash
cd /home/work8/netai/dev/sample-poc
git add manifests src images chart
git commit -m "Add sample-poc identity beacon: app + built image + chart"
git push -u origin main
git rev-parse HEAD          # ← 이 40자 SHA를 기록한다.  (이하 <CHILD_SHA>)
```

👀 push 직후 tower에서 PipelineRun이 **자동으로** 뜨는지 관찰(트리거 존재 여부 확인):
```bash
tkubectl -n tower-ci get pipelinerun --sort-by=.metadata.creationTimestamp
```
자동으로 뜨면 S6의 수동 제출은 건너뛰고 그 run을 관찰한다.

---

## S4. Federation PR① — source 허용

`scalex-federation/argocd/appproject.yaml`의 `spec.sourceRepos`에 정확한 URL을 추가한다.

```yaml
spec:
  sourceRepos:
    - https://github.com/BellTigerLee/sample-poc.git      # ← 추가
    # ...기존 항목 유지...
```

sample-poc는 `Deployment`와 `PropagationPolicy`만 렌더링하므로 `namespaceResourceWhitelist`는
그대로 둔다(둘 다 이미 허용됨). 검증 후 PR로 main에 merge.

```bash
cd /home/work8/netai/dev/scalex-federation
python3 tests/test_promotion_contract.py    # 통과 확인
```

---

## S5. Federation PR② — disabled release 등록

`releases/scalex-sample-poc/` 아래 **2개 파일**만 만든다. `values.yaml`은 만들지 않는다 —
S6의 promote가 생성한다.

### `releases/scalex-sample-poc/release.yaml`
```yaml
name: scalex-sample-poc
namespace: scalex-sample-poc
state: disabled
disabledReason: First build and Karmada member verification pending.
renderer: helm/v1
source:
  repoURL: https://github.com/BellTigerLee/sample-poc.git
  path: chart
  branch: main
values:
  path: releases/scalex-sample-poc/values.yaml
promotion:
  mode: tracking
  # resolvedRevision는 적지 않는다 — CI(federation-promote)가 관리한다. 최초 build 성공 시
  # promote가 이 값을 채워 PR로 올린다. 비워두면 promote 없이 active로 못 바꾼다(안전장치:
  # 계약 테스트가 active+tracking에 resolvedRevision 없으면 실패).
```

> **tracking의 `resolvedRevision`은 사람이 손으로 박지 않는다.** child SHA(`<CHILD_SHA>`)는
> S6의 PipelineRun `source-revision`으로만 넣고, `resolvedRevision`은 promote가 기록한다.
> (`pinned` 모드라면 대신 `source.revision: <40자 SHA>`를 사람이 명시한다.)

### `releases/scalex-sample-poc/runtime-values.yaml`
```yaml
{}
```
> `{}`라도 파일은 반드시 있어야 한다. promote의 `render-candidate`가 이 파일의 존재를
> 요구한다(없으면 `promotion values missing`으로 실패).

검증 후 PR로 main에 merge. `state: disabled`이므로 ApplicationSet은 아직 무시한다(배포 없음).
```bash
python3 tests/test_promotion_contract.py
```

🧑‍⚖️ 여기까지 merge되어야 S6의 promote가 `releases/scalex-sample-poc/release.yaml`을
main에서 찾을 수 있다. (없으면 `release not enrolled`)

---

## S6. Tekton child-build PipelineRun 제출 (1회)

`build-targets`를 **생략**한다 → T8이 `images/app/Dockerfile`에서 파생한다.
tower는 `promotion.enabled=true`이므로 build 성공 시 T10의 `promote`가 이어서 PR을 연다.

`sample-poc-build.yaml`:
```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: sample-poc-release-build-
  namespace: tower-ci
  labels:
    app.kubernetes.io/part-of: tekton-ci
    scalex.io/child-name: sample-poc
spec:
  pipelineRef:
    name: child-build
  taskRunTemplate:
    serviceAccountName: tekton-ci-runner
    podTemplate:
      securityContext:
        fsGroup: 65532
        fsGroupChangePolicy: OnRootMismatch
  params:
    - name: child-name
      value: sample-poc
    - name: repo-url
      value: https://github.com/BellTigerLee/sample-poc.git
    - name: source-revision
      value: <CHILD_SHA>
    - name: chart-path
      value: chart
    # build-targets 생략 → images/*/Dockerfile 파생 (T8)
    # allowed-kinds 생략 → namespaced 전용 (sample-poc는 cluster-scoped 없음)
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          storageClassName: rook-ceph-block-hot
          resources:
            requests:
              storage: 5Gi
```

```bash
tkubectl -n tower-ci create -f sample-poc-build.yaml
```

👀 관찰:
```bash
# 전체 진행
tkubectl -n tower-ci get pipelinerun -w
# task 단위 (validate-input→clone→derive-targets→helm-validate→build-push→create-promotion-payload→promote)
tkubectl -n tower-ci get taskrun --sort-by=.metadata.creationTimestamp
# 특정 task 로그 (예: 파생 결과 확인)
tkubectl -n tower-ci logs -l tekton.dev/pipelineTask=derive-targets --tail=-1
```

기대 결과:
- `derive-targets` → `[{"name":"app","valuesKey":"app","context":".","dockerfile":"images/app/Dockerfile"}]`
- `build-push` → `10.34.25.18/tower-ci/sample-poc/app:sha-<CHILD_SHA>` push, `:v0.1.0` alias
- `promote` → `ci/promote-sample-poc` 브랜치 push + PR 생성

🧑‍⚖️ 실패 시 자주 걸리는 지점:
| 증상 | 원인 |
|---|---|
| clone 단계 실패 | repo가 public이 아니거나 `<CHILD_SHA>`가 push 안 됨 |
| derive-targets 실패 | `images/app/Dockerfile` 경로/이름 문제 |
| build-push tag 실패 | `chart/values.yaml`의 `images.app.tag`가 `vX.Y.Z`가 아님 |
| promote `release not enrolled` | S5 PR②가 아직 main에 없음 |
| promote push 403 | GitHub App이 sample-poc가 아니라 **federation** repo 권한이면 정상. 확인 |

---

## S7. promotion PR 검토 + merge  🧑‍⚖️ (배포 승인 경계)

promote가 연 PR을 GitHub에서 연다 (제목: `chore(sample-poc): promote <sha>`).

diff가 **정확히 이 두 파일**로 제한되는지 확인한다:
- `releases/scalex-sample-poc/values.yaml` (신규 — `images.app`에 repository/tag/digest/sourceRevision)
- `releases/scalex-sample-poc/release.yaml` (`promotion.resolvedRevision` 갱신, 있을 경우)

확인 항목:
- [ ] image digest가 `sha256:<64hex>` 형태다
- [ ] `sourceRevision`이 `<CHILD_SHA>`와 같다
- [ ] `releases/scalex-sample-poc/` 밖의 변경이 없다

이상 없으면 **사람이 merge**한다. 이 merge가 곧 배포 승인이다.

---

## S8. Federation PR③ — 활성화

promotion PR merge 후, `releases/scalex-sample-poc/release.yaml`을 `state: active`로 바꾼다.

```yaml
state: active            # disabled → active
# disabledReason 줄은 삭제
```

활성화 전 로컬 렌더로 최종 확인:
```bash
cd /home/work8/netai/dev/scalex-federation
helm template scalex-sample-poc /home/work8/netai/dev/sample-poc/chart \
  --namespace scalex-sample-poc \
  --values releases/scalex-sample-poc/runtime-values.yaml \
  --values releases/scalex-sample-poc/values.yaml | \
  grep -E 'image:|clusterNames|kind:'
```
- [ ] Deployment image가 `@sha256:`로 고정
- [ ] PropagationPolicy `clusterNames`에 `c`
- [ ] `python3 tests/test_promotion_contract.py` PASS

PR로 merge. ApplicationSet이 `federation-scalex-sample-poc` Application을 생성한다.

---

## S9. 배포 확인

```bash
# Argo가 release를 Application으로 잡았는가
tkubectl -n argo get applicationset scalex-federation-releases
tkubectl -n argo get application federation-scalex-sample-poc

# Karmada가 워크로드를 받고 member c로 전파했는가
tkubectl -n scalex-sample-poc get deploy,propagationpolicy
tkubectl -n karmada-system get resourcebinding -n scalex-sample-poc 2>/dev/null || \
  tkubectl --kubeconfig <karmada-kubeconfig> -n scalex-sample-poc get rb

# 실제 member c 위의 pod
kubectl --context c -n scalex-sample-poc get pods -o wide
```

👀 **성공 기준**: member `c`에서 `scalex-sample-poc-...` pod가 `Running` + readiness 통과.

---

## S10. 정지 / rollback / offboard (참고)

```yaml
# 긴급 정지: releases/scalex-sample-poc/release.yaml
state: disabled           # Application이 사라지고 prune됨
```

```yaml
# rollback: 이전 검증된 조합으로 pin (federation PR로만)
source:
  revision: <이전 CHILD_SHA>
promotion:
  mode: pinned
# 같은 PR에서 values.yaml도 그 revision의 digest 조합으로 되돌린다
```

offboard 순서: `state: disabled` merge → member 잔여 확인 → `releases/scalex-sample-poc/` 삭제
→ AppProject `sourceRepos`에서 URL 제거 → `test_promotion_contract.py` → Harbor
`tower-ci/sample-poc/*` 삭제(Git 밖) → child repo 정리.

---

## 다음 배포 (2회차부터)

```text
코드 수정 → chart/values.yaml의 images.app.tag 상승(v0.1.1) → push
   → child-build PipelineRun (source-revision = 새 SHA)  → promote PR
   → 사람이 merge → Argo가 새 digest로 sync
```
`state`는 계속 `active`. S4/S5/S8은 반복하지 않는다.
