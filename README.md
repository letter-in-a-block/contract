# bottle-contracts

Message In a Bottle on-chain layer: `BottleSea` (bottle registry) + OpenZeppelin `ERC2771Forwarder` for gasless, wallet-less meta-transactions.

## Setup
```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup   # forge 1.9.0 used here
forge install                                              # lib/ is committed as submodules
cp .env.example .env
```
OpenZeppelin Contracts **v5.7.0** (`lib/openzeppelin-contracts`), solc 0.8.24, EVM cancun.

## Deployed (Base Sepolia, chainId 84532, verified on Basescan)
- Forwarder: `0x417261345EF348b6E2faFa5E1777C14026dF67d5`
- BottleSea: `0xD50E9a1FB06f9d4524Aec0714DD0c7bE7F417558`

Full spec: [`docs/SPEC.md`](docs/SPEC.md). Integration guide: [`docs/INTEGRATION.md`](docs/INTEGRATION.md).

## Commands
| | |
|---|---|
| `make build` / `make test` | build / run tests (16 tests) |
| `make anvil` | local node |
| `make deploy-local` | deploy to anvil (default accounts; writes `deployments/31337.json`) |
| `make deploy-sepolia` | Base Sepolia deploy (needs `.env`) |
| `make verify-sepolia` | Etherscan V2 source verification after deploy |
| `make abi` | extract ABIs to `abi/` |
| `forge coverage --report summary` | coverage (BottleSea.sol lines: 100%) |

Base Sepolia: fill `.env`, then `make deploy-sepolia`, then (optional) `make verify-sepolia`.

## Design decisions
- **Body off-chain**: only `contentHash = keccak256(uuid ‖ body)` is stored; chain proves who wrote it, who holds it, and that the body is untampered.
- **Picking and rethrowing are off-chain only**: PoW, random selection, holder tracking and re-floating live in the backend DB. On-chain records would let a thrower see that their bottle was picked or passed on, which contradicts the concept. The contract therefore has a single write function, `throwBottle`, and no roles/admin/operator.
- **Duplicate `contentHash` rejected**: makes backend re-sends idempotent (no double bottle).
- **Forwarder is stock OZ**, trusted forwarder is immutable in `BottleSea`.
- Direct `throwBottle` (without forwarder) works and sets `author = msg.sender`. Intended: it is harmless (caller pays own gas, still unique hash) and handy for tests.
- Bottle struct packed in 3 slots.

## Relayer notes (summary; details in `docs/INTEGRATION.md`)
- Use `executeBatch(requests, nonZeroRefundReceiver)`: with `address(0)`, **one invalid request reverts the whole batch**; with non-zero it is skipped (nonce not consumed).
- Valid-signature requests whose inner call reverts do **not** revert the batch (value = 0) but **do** consume the nonce.
- Hand out pending-aware nonces; deadline ≥ 2-3x batch interval; set tx gas ≥ Σ request.gas·64/63.

## 확인 필요
- `contentHash` encoding of `bottleUuid` (chosen: 36-char lowercase UTF-8 string) and body normalization must be agreed with backend/frontend.
- Per-request `gas` (200k) is not load-tuned; a real `Forwarder.execute` of one throw on Base Sepolia used 151,769 gas in total.
- Go/viem snippets in `docs/INTEGRATION.md` are not compiled/executed here (abigen is not installed); the EIP-712 digest itself is exercised by the Solidity tests.
- Because rethrow is backend-only, "how many times a bottle was thrown" cannot be proven on-chain.
