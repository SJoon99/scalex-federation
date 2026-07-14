# 공통 소유권 계약

ScaleX 배포 경로는 Infra, feature repository, Federation의 책임을 분리한다.

| 계층 | 소유하는 것 | 소유하지 않는 것 |
|---|---|---|
| Infra Layer | Karmada 설치·member join, Argo CD, CNI/CSI, SecretStore와 외부 secret 값 | feature source와 release revision |
| Feature repository | source, 독립 image build context, cluster-neutral Helm chart, test와 package | placement, cluster 이름, runtime credential |
| `scalex-federation` | 승인된 child URL/path, exact chart commit, image tag+digest, runtime values, ESO reference, Karmada policy | image build, 평문 secret, member cluster 직접 배포 |

Feature chart는 `Secret`, `ExternalSecret`, Karmada policy, cluster-scoped resource를
렌더링하지 않는다. Federation은 credential 값 대신 승인된 `SecretStore`, target
Secret 이름과 external key 이름만 선언한다. 실제 값은 Infra Layer의 외부 저장소가
제공한다.

Release는 `scalex.io/v1alpha1` `FederationRelease`이며 `renderer: helm/v1`, 공개
repository URL, 승인된 chart path, full 40-character commit을 사용한다. 배포 image는
명시적 tag와 `sha256` digest를 함께 기록한다. `latest` alias가 registry에 있더라도
desired state에서는 사용할 수 없다.

Tower Argo CD의 destination은 `karmada` 하나다. Karmada가 `b`, `c` member에
복제하며 Argo가 member에 같은 리소스를 직접 관리하지 않는다. Git manifest, CI
render 성공, source pin은 desired state의 증거일 뿐 실제 sync·placement·workload
health의 증거가 아니다. Runtime 성공은 보호된 관찰 workflow의 별도 결과로만
판정한다. 현재 workflow는 `karmada`, `b`, `c`만 관찰하며 Tower control API의
Argo Application sync/health는 별도 권한이 없으므로 NOT RUN으로 남긴다.
