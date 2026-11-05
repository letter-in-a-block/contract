# Message In a Bottle — 컨트랙트 명세

## 1. 목적과 범위
익명 병편지 서비스의 온체인 레이어. 체인이 증명하는 것은 단 하나다.

> **누가, 언제, 어떤 본문 해시로 병을 던졌는가.**

본문, 줍기, 보유자, 재던지기는 모두 오프체인(백엔드 DB)이 담당한다. 이유는 컨셉이다. 실제 바다에서 병을 던지면 누가 주웠는지 알 수 없다. 줍기·재던지기를 온체인에 남기면 던진 사람이 체인을 보고 병이 주워졌음을 알 수 있어서 의도적으로 뺐다.

범위: 컨트랙트 레이어만. Go 백엔드, React 프론트, Relayer Worker는 포함하지 않는다.

## 2. 구성

| 컨트랙트 | 출처 | 역할 |
|---|---|---|
| `ERC2771Forwarder("BottleForwarder")` | OpenZeppelin v5.7.0, 수정 없음 | 사용자 EIP-712 서명 검증, nonce 관리, 가스 대납 실행 |
| `BottleSea` | `src/BottleSea.sol` | 병 등록. `ERC2771Context` 상속, Forwarder는 생성자에서 고정(immutable) |

권한 구조(admin/operator/role)는 없다. 쓰기 함수가 `throwBottle` 하나뿐이고 누구나 호출할 수 있기 때문이다.

## 3. BottleSea 인터페이스

### 3-1. 상태
```solidity
struct Bottle {
    address author;      // 병을 던진 사람 (Forwarder 경유 시 서명자)
    uint64  thrownAt;    // 던진 시각 (block.timestamp)
    bytes32 contentHash; // keccak256(bottleUuid ‖ body)
}                        // 스토리지 2슬롯: [author|thrownAt], [contentHash]

uint256 public nextId;                        // 마지막 발급 id (id는 1부터)
mapping(uint256 => Bottle) public bottles;
mapping(bytes32 => uint256) public idByHash;  // contentHash → id
```

### 3-2. 함수
| 함수 | 호출자 | 동작 |
|---|---|---|
| `constructor(address trustedForwarder)` | 배포자 | zero address면 `ZeroAddress`. 이후 Forwarder 변경 불가 |
| `throwBottle(bytes32 contentHash) returns (uint256 id)` | 누구나 (보통 Forwarder 경유) | `contentHash != 0`, 중복 아님을 확인하고 새 id 발급, `author = _msgSender()`. `BottleThrown` 발생 |
| `getBottle(uint256 id) view returns (Bottle)` | 누구나 | 조회. 없는 id는 zero 값 반환 |
| `bottles(id)`, `idByHash(hash)`, `nextId()` | 누구나 | public getter |
| `isTrustedForwarder(addr)`, `trustedForwarder()` | 누구나 | OZ 제공 |

### 3-3. 이벤트
```solidity
event BottleThrown(uint256 indexed id, address indexed author, bytes32 indexed contentHash, uint64 thrownAt);
```

### 3-4. 에러
`ZeroAddress`, `EmptyHash`, `DuplicateHash`

### 3-5. 동작 규칙
- `contentHash` 중복은 거부한다. 백엔드가 같은 요청을 다시 보내도 같은 병이 두 번 생기지 않게 하는 멱등성 장치다.
- Forwarder를 거치지 않고 직접 호출해도 동작하며 `author = msg.sender`가 된다. 의도된 동작이다(호출자가 자기 가스를 낸다).
- 체인은 `contentHash`만 알고 본문은 모른다. 본문 변조 여부는 `keccak256(uuid ‖ body)`를 다시 계산해 비교한다.

## 4. 흐름

```
[던지기]  Client: throwBottle(contentHash) calldata → ForwardRequest(EIP-712) 서명 → 백엔드
          Backend: 서명 오프체인 검증 → DB 저장 → 10분 배치
          Relayer: Forwarder.executeBatch(...) (가스 지불)
          BottleSea: _msgSender() = 서명한 사용자 → 병 생성 → BottleThrown

[받기]    온체인 없음. 서버가 PoW 검증 후 병을 선택해 본문을 DB에서 반환
[다시 던지기] 온체인 없음. 백엔드가 병을 DB 풀로 되돌림
```

사용자는 지갑/가스비 없이 브라우저 로컬 키로 자동 서명한다.

## 5. contentHash 규칙
```
contentHash = keccak256( UTF8(bottleUuid) ‖ UTF8(body) )
```
`bottleUuid`는 백엔드가 발급한 36자 소문자 문자열. 고정 길이라 단순 이어붙이기가 모호하지 않다. 같은 본문이라도 병마다 해시가 달라진다.

## 6. Forwarder 동작 (OZ v5.7.0 소스 기준, 테스트로 검증)
- 서명 대상: `ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)`. `nonce`는 서명에는 들어가지만 calldata 구조체(`ForwardRequestData`)에는 없고 `nonces(from)`에서 읽는다.
- EIP-712 도메인: name `BottleForwarder`, version `1`.
- `executeBatch(requests, refundReceiver)`:
  - `refundReceiver == 0`: 무효 요청이 하나라도 있으면 **전체 revert**
  - `refundReceiver != 0`: 무효 요청은 **건너뛰고 nonce도 소모하지 않음**
  - 서명은 유효한데 내부 호출만 실패(예: `DuplicateHash`)하면 value가 0일 때 배치는 revert하지 않고 **nonce는 소모**됨
- 요청별 `gas`가 모자라면 Forwarder가 `invalid()`로 트랜잭션 가스를 전부 소모한다.

## 7. 테스트 (`test/BottleSea.t.sol`, 16개)
`vm.sign`으로 실제 EIP-712 서명을 만들어 Forwarder를 통과시킨다.
- 던지기: 정상(author=서명자≠Relayer), 서명 위조, replay, 틀린 nonce, 만료 deadline, 중복 해시, zero 해시
- 배치: 다중 사용자, 무효 요청 혼입(`refundReceiver` 0 / 非0 각각), 내부 호출 실패 시 nonce 소모
- 컨텍스트: `isTrustedForwarder`, 직접 호출 시 `author = msg.sender`, `Forwarder.verify`
- 생성자: zero forwarder 거부

`BottleSea.sol` 라인 커버리지 100%.

## 8. 배포 현황

| 네트워크 | chainId | Forwarder | BottleSea |
|---|---|---|---|
| Base Sepolia | 84532 | `0x417261345EF348b6E2faFa5E1777C14026dF67d5` | `0xD50E9a1FB06f9d4524Aec0714DD0c7bE7F417558` |
| anvil (로컬) | 31337 | `deployments/31337.json` 참조 | |

- Base Sepolia: 두 컨트랙트 모두 Basescan 소스 검증 완료.
- 스모크 테스트(Base Sepolia): 잔액 0인 사용자가 서명하고 배포자 지갑이 Relayer로 `Forwarder.execute`를 호출. 트랜잭션 sender는 Relayer, 온체인 `author`는 서명자로 기록됨. [tx](https://sepolia.basescan.org/tx/0xb4c5da61369f958b96e5a8d1186b374dee6c43ba3502e92d6087dce45c1e8238)
- 재실행: `forge script script/ThrowSmoke.s.sol --rpc-url base_sepolia --broadcast`

## 9. 알려진 한계 / 확인 필요
- 줍기·재던지기가 오프체인이므로 "몇 번 던져졌나", "지금 누가 들고 있나"는 체인이 증명하지 못한다.
- 병 id 1은 스모크 테스트용 병이다(본문 `hello bottle`, uuid `smoke-<timestamp>`). 실서비스 전에는 새 배포를 권장한다.
- 요청별 `gas`(200k)는 실제 부하로 튜닝하지 않았다. 스모크 테스트의 `Forwarder.execute` 트랜잭션 실측 가스는 151,769.
- Go/viem 예시 코드(`INTEGRATION.md`)는 컴파일·실행하지 않았다. `abigen`은 설치하지 않았다.
- `contentHash`의 uuid 인코딩과 본문 정규화 규칙은 백엔드·프론트와 합의가 필요하다.
