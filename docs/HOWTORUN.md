# Child feature 연결 및 실행

## 새 feature release 등록

1. feature repository에 cluster-neutral Helm chart, image build와 테스트를 완성한다.
2. exact repository URL/chart path를 `contracts/children.yaml`과
   `bootstrap/appproject.yaml`에 wildcard 없이 동일하게 등록한다.
3. `releases/<environment>/<release>/release.yaml`에 full chart SHA,
   values/dependencies/policy path와 promotion mode를 적는다.
4. `values.yaml`에 모든 image tag+digest와 기존 runtime binding 이름을 기록한다.
5. release claim/non-secret mapping은 `dependencies/`, placement/override는 `policy/`에 둔다.
6. 정적 검증 후 PR로 merge한다. CI는 cluster에 직접 apply하지 않는다.

```bash
FEATURE_REPOS_ROOT=/path/to/checkouts ./scripts/validate.sh
./tests/test-runtime-bindings.sh
./tests/contracts/test-script-boundaries.sh
```

## Runtime binding 동기화

Argo sync 후 source cluster의 OBC가 `Bound`이고 Rook 생성 Secret/ConfigMap이 준비된
상태에서 Tower management-plane에서 공통 runner를 실행한다.

member kubeconfig 디렉터리는 binding의 `sourceCluster`와 파일 이름을 일치시킨다.

```text
/secure/member-kubeconfigs/
├── b.kubeconfig
└── c.kubeconfig
```

모든 release의 binding을 label로 조회해 동기화한다.

```bash
KARMADA_KUBECONFIG=/path/to/karmada-kubeconfig \
MEMBER_KUBECONFIG_DIR=/secure/member-kubeconfigs \
./scripts/sync-runtime-bindings.sh --all
```

하나의 binding만 재처리할 수도 있다.

```bash
KARMADA_KUBECONFIG=/path/to/karmada-kubeconfig \
MEMBER_KUBECONFIG_DIR=/secure/member-kubeconfigs \
./scripts/sync-runtime-bindings.sh \
  --binding scalex-rgw-analysis-web/rgw-analysis-web-storage-binding
```

runner는 `scalex.io/runtime-binding=true` ConfigMap을 발견하고 `sourceCluster`에 해당하는
kubeconfig로 source output을 읽는다. 현재 지원 adapter는
`rook-obc-s3/v1alpha1`이며, Karmada에 normalized Secret+ConfigMap을 server-side apply한다.
Secret 내용은 출력하지 않는다. target 객체는 binding ConfigMap을 owner로 가져 binding
삭제 시 함께 정리된다.

완료 후 release를 다시 sync하여 one-shot Job을 재실행하고 ResourceBinding, member Pod,
result endpoint를 확인한다.

```text
Argo dependencies sync
  → source OBC Bound
  → common RuntimeBinding runner
  → Karmada runtime binding
  → workload sync/retry
  → runtime observation
```

새 feature는 feature 전용 credential script를 추가하지 않는다. 지원 중인 binding type을
재사용하거나, 새로운 dependency 종류가 필요하면 공통 runner에 경계가 명확한 adapter와
회귀 테스트를 함께 추가한다. 임의 Secret/resource 복사 기능은 허용하지 않는다.

현재 고정 bucket은 migration 호환용이므로 데이터 정리 승인 없이 OBC/ObjectBucket을
삭제하지 않는다.
