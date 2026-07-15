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
./tests/test-storage-binding.sh
./tests/contracts/test-script-boundaries.sh
```

## RGW POC 첫 적용 또는 credential 재생성

Argo sync 후 B OBC가 `Bound`이고 Rook 생성 Secret/ConfigMap이 준비된 상태에서 실행한다.

```bash
B_KUBECONFIG=/path/to/b-kubeconfig \
KARMADA_KUBECONFIG=/path/to/karmada-kubeconfig \
./scripts/sync-object-storage-binding.sh
```

스크립트는 binding ConfigMap을 읽고 Karmada에 normalized Secret+ConfigMap을
server-side apply한다. Secret 내용은 출력하지 않는다. 완료 후 release를 다시 sync하여
one-shot Job을 재실행하고 ResourceBinding, B/C Pod, result-web HTTP를 확인한다.

```text
Argo dependencies sync
  → B OBC Bound
  → binding script
  → Karmada runtime binding
  → workload sync/retry
  → runtime observation
```

현재 고정 bucket은 migration 호환용이므로 데이터 정리 승인 없이 OBC/ObjectBucket을
삭제하지 않는다.
