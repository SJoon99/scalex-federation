# Child feature 연결 방법

새 child feature는 공개 repository에 source, image context, cluster-neutral Helm
chart와 로컬 검증 entry point를 먼저 완성한다. Secret 값, kubeconfig, cluster 이름,
Karmada manifest는 child에 넣지 않는다.

1. `contracts/children.yaml`에 exact HTTPS GitHub URL과 허용 chart path를 추가한다.
2. 같은 exact URL을 `bootstrap/appproject.yaml`의 `sourceRepos`에 추가한다. 두 목록은
   wildcard 없이 일치해야 한다.
3. `releases/<environment>/<feature>/release.yaml`에 full source commit, `helm/v1`,
   values/dependencies/policy path와 `tracked` 또는 `pinned` mode를 선언한다.
4. `values.yaml`에는 CI가 발행한 component별 tag, digest, source revision을 한 번에
   기록한다. 실제 registry digest를 모르면 placeholder로 release를 만들지 않는다.
5. 현재 RGW release의 `dependencies/`에는 배포 YAML을 두지 않는다. Runtime Secret은
   승인된 bootstrap 경계에서 Karmada API에 준비하고 placement/override만 `karmada/`에 둔다.
6. feature repository checkout을 Federation의 sibling에 두고 검증한다.

```bash
FEATURE_REPOS_ROOT=/path/to/public-checkouts ./scripts/validate.sh
./tests/contracts/test-release-contract.sh
./tests/contracts/test-validation-fixtures.sh
```

Cuty RGW release는 Argo sync 전에 B의 OBC Secret을 Karmada native Secret으로 준비한다.
Credential 값이나 kubeconfig는 repository에 저장하지 않는다.

```bash
B_KUBECONFIG=/path/to/b-kubeconfig \
KARMADA_KUBECONFIG=/path/to/karmada-kubeconfig \
./scripts/bootstrap-cuty-rgw-credentials.sh
```

CI를 도입할 때는 exact origin/SHA/tree를 새로 가져와 같은 검증을 반복하고 public
image tag가 선언 digest를 가리키는지 확인한다. 이 단계는 cluster에 접근하거나
배포하지 않는다.
