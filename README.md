# Beanstalk Governance Flash-Loan Trap (Drosera)

A Drosera governance-risk demo based on the April 2022 Beanstalk exploit.
Demonstrates how a Trap detects a governance proposal crossing its execution threshold inside a protocol delay window and triggers an emergency pause and proposal cancellation.

---

## Canonical Version: V4

**V4 is the canonical implementation.**

Older top-holder concentration logic (V2–V3) is archived in `src/v2/` and `src/v3/` as historical context only.

---

## V4 Detection Invariant

The Trap fires when **all** of the following hold across two consecutive block samples for the **same `proposalId`**:

| Condition | Check |
|---|---|
| Threshold crossed | `current.proposalForVotes >= current.proposalThresholdVotes` |
| Was below threshold | `previous.proposalForVotes < previous.proposalThresholdVotes` |
| Same proposal tracked | `current.proposalId == previous.proposalId` |
| Proposal queued | `current.queued == true` |
| Delay window active | `current.readyBlock > current.blockNumber` |
| Not paused | `current.paused == false` |
| Not executed | `current.executed == false` |
| Not canceled | `current.canceled == false` |

Requires `block_sample_size = 2`.

### Reason Precedence

When the invariant fires, reason selection is deterministic:

1. `REASON_SINGLE_WHALE_SUPPORT` — if `topSupporterVotes >= proposalThresholdVotes`
2. `REASON_COORDINATED_MULTI_SUPPORTER` — if `supportVoterCount > 1`
3. `REASON_THRESHOLD_CROSS_DELAY_WINDOW` — otherwise

---

## Scope and Limits

- This project does not claim to interrupt an atomic same-transaction exploit.
- The original Beanstalk exploit executed governance power acquisition and execution in one transaction.
- A per-block Trap can only respond between blocks, so protocol-side delay and pause hooks are required for practical mitigation.

---

## Architecture

```
BeanstalkTrapV4.collect()          reads governance state each block
         |
         v
BeanstalkTrapV4.shouldRespond()    compares current vs previous block snapshots
         |
         v
BeanstalkVaultV4.executeResponse() pauses protocol + cancels proposal
```

Design properties:

- No off-chain watcher, oracle, or keeper.
- `collect()` is a `view` function reading protocol state on-chain.
- `shouldRespond()` requires a two-block window (`block_sample_size = 2`).
- Response path is permissioned via `onlyDrosera` in the vault.
- Protocol execution includes a one-block delay window before `executeProposal()`.

---

## V4 Contracts

| Contract | Purpose |
|---|---|
| `src/interfaces/ITrap.sol` | Drosera Trap interface |
| `src/BeanstalkGovernanceMockV4.sol` | Governance protocol mock with proposal + pause model |
| `src/BeanstalkTrapV4.sol` | Proposal-threshold delay-window detector |
| `src/BeanstalkTypesV4.sol` | Shared types, constants, and structs |
| `src/BeanstalkVaultV4.sol` | Permissioned response: pause + cancel proposal |

---

## Tests

```bash
forge test -vv
```

| File | Coverage |
|---|---|
| `test/BeanstalkMitigationV4.t.sol` | V4 integration, boundary, fuzz (canonical) |
| `test/v3/BeanstalkMitigationV3.t.sol` | V3 archive tests |
| `test/v2/BeanstalkMitigationV2.t.sol` | V2 archive tests |

---

## Deploy (Hoodi)

Drosera currently targets Hoodi testnet.

```bash
export RPC_URL="https://ethereum-hoodi-rpc.publicnode.com"
export PRIVATE_KEY="0x..."
# Optional override if Drosera response calls come from a dedicated address
export DROSERA_CALLER="0x..."
chmod +x deploy-hoodi.sh
./deploy-hoodi.sh
drosera apply
```

The deploy script writes `drosera.toml` with:

- Deployed trap and response addresses
- `block_sample_size = 2`
- `response_function = "executeResponse(bytes)"`

---

## Historical Context: V2–V3 (Top-Holder Concentration)

Older versions archived in `src/v2/` and `src/v3/` detected governance risk by tracking the top STALK holder's concentration:

- **V2** (`src/v2/`): First implementation. Detects when a single address crosses 67% of total STALK and queues an emergency commit. Uses `uint8` for status/reason fields.
- **V3** (`src/v3/`): Upgraded to `uint256` fields, assembly decoding, and `shouldAlert()` for operational health signaling. 88 tests, 0 failures.

These approaches are historical context only. V4's proposal-level invariant is more precise because it tracks the actual proposal lifecycle and `proposalId` across samples rather than raw stake balance — eliminating false positives from large legitimate holders who never queue a proposal.
