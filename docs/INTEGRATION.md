# Integration Guide (Go backend / React frontend)

Contracts: `BottleSea` + OpenZeppelin `ERC2771Forwarder` (v5.7.0, unmodified). Addresses: `deployments/<chainId>.json`. ABIs: `abi/`.

## 1. EIP-712 domain and types

Copied from the installed OZ source (`lib/openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol`):

```
EIP712Domain: name="BottleForwarder", version="1", chainId, verifyingContract=<Forwarder address>

ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)
```

Notes:
- `nonce` is part of the **signed** struct but is **not** a field of the on-chain `ForwardRequestData` calldata struct. The forwarder reads it from `nonces(from)`.
- `ForwardRequestData = (address from, address to, uint256 value, uint256 gas, uint48 deadline, bytes data, bytes signature)`.
- `to` = BottleSea address, `value` = 0.

## 2. Frontend (viem)

```ts
import { createWalletClient, createPublicClient, http, encodeFunctionData, keccak256, toBytes, concat } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import bottleSeaAbi from "./abi/BottleSea.json";
import forwarderAbi from "./abi/ERC2771Forwarder.json";

// 1) local key: created once, stored in the browser, no wallet UI
function loadAccount() {
  let pk = localStorage.getItem("bottle_pk") as `0x${string}` | null;
  if (!pk) { pk = generatePrivateKey(); localStorage.setItem("bottle_pk", pk); }
  return privateKeyToAccount(pk);
}

// 2) contentHash (see section 4)
const contentHash = (uuid: string, body: string) =>
  keccak256(concat([toBytes(uuid), toBytes(body)]));

// 3) sign a throw
async function signThrow(uuid: string, body: string, cfg: { forwarder: `0x${string}`; bottleSea: `0x${string}`; chainId: number }) {
  const account = loadAccount();
  // IMPORTANT: ask the BACKEND for the next nonce (it accounts for pending, unrelayed requests).
  const nonce = await fetch(`/api/nonce?address=${account.address}`).then(r => r.json()).then(j => BigInt(j.nonce));
  // (reading fwd.nonces(from) on-chain is only correct when nothing is pending)

  const data = encodeFunctionData({ abi: bottleSeaAbi, functionName: "throwBottle", args: [contentHash(uuid, body)] });
  const deadline = Math.floor(Date.now() / 1000) + 30 * 60; // >= 2-3x batch interval (10 min)
  const message = { from: account.address, to: cfg.bottleSea, value: 0n, gas: 200_000n, nonce, deadline, data };

  const signature = await account.signTypedData({
    domain: { name: "BottleForwarder", version: "1", chainId: cfg.chainId, verifyingContract: cfg.forwarder },
    types: { ForwardRequest: [
      { name: "from", type: "address" }, { name: "to", type: "address" },
      { name: "value", type: "uint256" }, { name: "gas", type: "uint256" },
      { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint48" },
      { name: "data", type: "bytes" },
    ]},
    primaryType: "ForwardRequest",
    message,
  });

  // JSON for the backend (bigints as decimal strings)
  return { uuid, body, request: {
    from: message.from, to: message.to, value: "0", gas: message.gas.toString(),
    nonce: nonce.toString(), deadline, data, signature,
  }};
}
```

Only `throwBottle` is signed on-chain. Picking and rethrowing are backend-only (see section 5).

## 3. Backend (Go, go-ethereum) verification

```go
import (
    "bytes"
    "github.com/ethereum/go-ethereum/common"
    "github.com/ethereum/go-ethereum/common/math"
    "github.com/ethereum/go-ethereum/crypto"
    "github.com/ethereum/go-ethereum/signer/core/apitypes"
)

func verify(chainID int64, forwarder common.Address, r Req) (bool, error) {
    td := apitypes.TypedData{
        Types: apitypes.Types{
            "EIP712Domain": {{Name: "name", Type: "string"}, {Name: "version", Type: "string"},
                {Name: "chainId", Type: "uint256"}, {Name: "verifyingContract", Type: "address"}},
            "ForwardRequest": {{Name: "from", Type: "address"}, {Name: "to", Type: "address"},
                {Name: "value", Type: "uint256"}, {Name: "gas", Type: "uint256"},
                {Name: "nonce", Type: "uint256"}, {Name: "deadline", Type: "uint48"},
                {Name: "data", Type: "bytes"}},
        },
        PrimaryType: "ForwardRequest",
        Domain: apitypes.TypedDataDomain{Name: "BottleForwarder", Version: "1",
            ChainId: math.NewHexOrDecimal256(chainID), VerifyingContract: forwarder.Hex()},
        Message: apitypes.TypedDataMessage{
            "from": r.From.Hex(), "to": r.To.Hex(), "value": r.Value, "gas": r.Gas,
            "nonce": r.Nonce, "deadline": r.Deadline, "data": r.Data, // data as 0x-hex string
        },
    }
    hash, _, err := apitypes.TypedDataAndHash(td) // keccak256(0x1901 || domainSep || structHash)
    if err != nil { return false, err }

    sig := bytes.Clone(r.Signature) // 65 bytes r||s||v
    if sig[64] >= 27 { sig[64] -= 27 }
    pub, err := crypto.SigToPub(hash, sig)
    if err != nil { return false, err }
    return crypto.PubkeyToAddress(*pub) == r.From, nil
}
```

Double check (optional): call the forwarder's `verify(ForwardRequestData)` view function via `eth_call` — it checks trusted target, deadline and signature against the **on-chain** nonce. If you track pending nonces off-chain, `verify` will fail for n+1 requests until n is mined; use it only for the first pending request of a user, or skip it.

## 4. contentHash rule (frontend and backend must match)

```
contentHash = keccak256( UTF8(bottleUuid) || UTF8(body) )
```
- `bottleUuid`: canonical lowercase 36-char string (`xxxxxxxx-xxxx-...`), issued by the backend. Fixed length, so plain concatenation is unambiguous.
- `body`: exact UTF-8 bytes stored in MySQL. Decide one normalization (recommended: no transformation; hash what you store) and use it on both sides.
- Equivalent Solidity: `keccak256(abi.encodePacked(bottleUuid, body))` with both as `string`.

## 5. Relayer notes

- **Nonces are sequential per user.** If requests n and n+1 from one user are in the same batch and n is invalid/fails validation, n+1 also fails (its signed nonce no longer matches). The backend must hand out `confirmed_nonce + pending_count` to clients.
- **Deadline**: at least 2-3x the batch interval (10 min) → 30 min recommended.
- **`executeBatch(requests, refundReceiver)` behaviour (verified by tests against OZ v5.7.0 source):**
  | Case | `refundReceiver == address(0)` | `refundReceiver != 0` |
  |---|---|---|
  | Invalid request (bad signature / wrong nonce / expired / untrusted target) | **Whole batch reverts**, nothing executes | Request is **skipped**, nonce **not** consumed, others execute |
  | Valid signature but inner call reverts (e.g. `DuplicateHash`, `NotHolder`) with `value == 0` | Batch does **not** revert; nonce **is consumed**; `ExecutedForwardRequest(signer, nonce, false)` emitted | Same |
  
  Recommendation: pass a non-zero `refundReceiver` (e.g. the relayer address; value is always 0 so nothing is refunded) so one bad request cannot kill the batch. Then reconcile per request with `ExecutedForwardRequest(signer, nonce, success)` events.
- **Single `execute`** reverts with `FailedCall` if the inner call fails (original reason is lost). Simulate with `eth_call` directly against BottleSea (`from = user`) if you need the reason.
- **Gas**: each request carries its own `gas`. If the forwarder finds less than `gas/63` left after the call it executes `invalid()` and burns the whole tx gas. Set the tx gas limit to cover `sum(request.gas) * 64/63` plus overhead (estimate via `eth_estimateGas`).
- **Relayer wallet nonce** (tx nonce) is independent of user forwarder nonces; manage it separately (serialize sends or track locally).
- **Reorgs**: re-sending after a reorg cannot double-execute: forwarder nonce is consumed on execution, and `idByHash` rejects duplicate throws.
- **Picking and rethrowing are not on-chain.** The backend alone decides who holds a bottle and re-floats it, so a thrower cannot observe that a bottle was picked or passed on. To "rethrow", the backend just returns the bottle to its DB pool; nothing is sent to the chain.
- If you ever want a rethrown bottle on-chain, sign a fresh `throwBottle` with a **new** `contentHash` (new uuid). It becomes an unlinked new bottle on-chain.

## 6. Events → DB state

| Event | DB action |
|---|---|
| `BottleThrown(id, author, contentHash, thrownAt)` | Find row by `contentHash`; set `chain_id = id`, `author_addr`, `thrown_at` |
| `ExecutedForwardRequest(signer, nonce, success=false)` (forwarder) | Mark the user's request `(signer, nonce)` as failed; do not retry (nonce consumed) |

Holder, pick and rethrow state live only in MySQL.

## 7. Go bindings

```bash
go install github.com/ethereum/go-ethereum/cmd/abigen@latest
abigen --abi abi/BottleSea.json --pkg bottle --type BottleSea --out bottle/bottlesea.go
abigen --abi abi/ERC2771Forwarder.json --pkg bottle --type Forwarder --out bottle/forwarder.go
```
