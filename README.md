# Beanstalk Governance Flash-Loan Trap (Drosera)

This repository is a production-inspired Drosera governance-risk demo based on the April 2022 Beanstalk exploit.
It demonstrates how a Trap can detect suspicious governance-power concentration and trigger a pause response when the protocol provides at least one block of reaction window.

---

## Scope and Limits

- This project does not claim to interrupt an atomic same-transaction exploit.
- The original Beanstalk exploit executed governance power acquisition and execution in one transaction.
- A per-block Trap can only respond between blocks, so protocol-side delay and pause hooks are required for practical mitigation.

---

## Architecture

```
BeanstalkTrap.collect()          reads governance state each block
         |
         v
BeanstalkTrap.shouldRespond()    compares current vs previous block snapshots
         |
         v
BeanstalkVault.executeResponse() authorized caller triggers protocol pause
```

Design properties:

- No off-chain watcher, oracle, or keeper.
- `collect()` is a `view` function reading protocol state on-chain.
- `shouldRespond()` requires a two-block window (`block_sample_size = 2`).
- Response path is permissioned via `onlyDrosera` in the vault.
- Protocol execution includes a one-block delay window before `emergencyCommit()`.

---

## Detection Invariant

The Trap fires when all are true from previous block to current block:

1. Current top-holder stake reaches at least 67% of total stake.
2. Top-holder stake increased versus previous block.
3. Top-holder still sits inside the protocol delay window (`readyBlock > block.number`).

If the top holder changed between snapshots, that transition is treated as suspicious (holder-flip takeover path) rather than ignored.
This keeps detection precise and avoids steady-state false positives for large holders.

---

## Contracts

| Contract                    | Purpose                                                  |
| --------------------------- | -------------------------------------------------------- |
| `src/interfaces/ITrap.sol`  | Drosera Trap interface                                   |
| `src/BeanstalkMock.sol`     | Simplified governance protocol with pause-guardian model |
| `src/BeanstalkTrap.sol`     | Delay-window governance concentration detector           |
| `src/BeanstalkVault.sol`    | Permissioned response contract                           |
| `src/BeanstalkAttacker.sol` | Attack simulator used in tests                           |

---

## Tests

```bash
forge test -vv
```

**88 tests, 0 failures** (5 fuzz targets × 256 runs each).

| Section                                  | Count | Coverage                                                                           |
| ---------------------------------------- | ----- | ---------------------------------------------------------------------------------- |
| A – Integration smoke tests              | 5     | Baseline attack, Drosera mitigation, top-holder flip, false-positive, auth         |
| B – `collect()` unit tests               | 11    | Output size, field values, paused flag, ready-block, zero-stalk guard              |
| C – `shouldRespond()` boundary tests     | 16    | Empty inputs, below-supermajority, exact boundary, paused snapshot, delay window   |
| D – False-positive / safe-path tests     | 5     | Static large holder, small increase, sub-majority, zero change, drained state      |
| E – Top-holder transition tests          | 4     | FLIP label, same-holder no-flip, benign overtake, zero-address prev                |
| F – `BeanstalkVault` unit tests          | 13    | Auth, cooldown, first-call, event, response count, immutables, zero-address guards |
| G – `BeanstalkTrap` configuration tests  | 8     | Owner, configure once, non-owner revert, zero-address revert, constants            |
| H – `BeanstalkMock` access-control tests | 15    | Guardian gate, supermajority gate, delay enforcement, pause state, atomic revert   |
| I – Multi-block integration tests        | 6     | Vault pauses before delay expires, cooldown config, end-to-end flow, two attackers |
| J – Fuzz tests                           | 5     | Junk data safety, below-supermajority invariant, determinism, cooldown, count      |

Full test file: `test/BeanstalkMitigation.t.sol`

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

## Why This Version Is Reviewer-Aligned

- Removes the claim that Drosera can interrupt same-transaction atomic execution.
- Uses correct Drosera data ordering (`data[0]` current, `data[1]` previous).
- Uses `block_sample_size = 2` to support snapshot comparison.
- Restricts response execution to an authorized caller.
- Restricts protocol pause to configured pause guardian.
- Removes known-attacker coupling by monitoring current top-holder state.
- Removes trap constructor arguments by using one-time `configure(address)`.
