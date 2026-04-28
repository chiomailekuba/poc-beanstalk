# Beanstalk Governance Flash-Loan Trap (Drosera)

A **Drosera Trap** that detects and mitigates the on-chain conditions that enabled the [Beanstalk Farms $182M governance flash-loan attack](https://rekt.news/beanstalk-rekt/) on April 17, 2022 — with zero off-chain dependencies.

---

## The Real Attack

On **April 17, 2022, block 14,602,790**, an attacker:

1. Flash-borrowed enough STALK to hold **67.08% of total governance power** in a single block
2. Immediately called `emergencyCommit()` to pass BIP-18
3. Drained **~$182 million** from the Beanstalk treasury

No alarm fired. No human reacted in time. The entire attack happened in one block.

Drosera is the only class of infrastructure that could have stopped this — because it monitors every block, purely on-chain, with no off-chain attack surface.

---

## Architecture

```
BeanstalkTrap.collect()          reads totalStalk + candidateStalk every block
         |
         v
BeanstalkTrap.shouldRespond()    compares block[N-1] vs block[N]:
                                 fires if stake jumped to >= 67% of totalStalk
         |
         v
BeanstalkVault.executeResponse() calls protocol.pause() before emergencyCommit() can run
```

**No off-chain watcher. No oracle. No keeper. No Store contract.**
`collect()` is a pure `view` function that reads directly from the protocol.

---

## Detection Invariant

The Trap fires when **both** conditions are true between consecutive blocks:

1. `candidateStalk[N] * 100 >= totalStalk[N] * 67` — supermajority reached
2. `candidateStalk[N] > candidateStalk[N-1]` — stake increased this block

Condition 2 prevents false positives on accounts that legitimately hold large STALK positions across many blocks.

---

## Contracts

| Contract                    | Purpose                                                |
| --------------------------- | ------------------------------------------------------ |
| `src/interfaces/ITrap.sol`  | Drosera ITrap interface                                |
| `src/BeanstalkMock.sol`     | On-chain replica of vulnerable Beanstalk governance    |
| `src/BeanstalkTrap.sol`     | The Drosera Trap — implements ITrap                    |
| `src/BeanstalkVault.sol`    | Response contract — calls `pause()` when Trap fires    |
| `src/BeanstalkAttacker.sol` | Simulates the April 2022 attacker (test/demo use only) |

---

## Quickstart

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Drosera CLI](https://docs.drosera.io/getting-started/quick-start)

### Build

```bash
forge build
```

### Test (all 3 pass)

```bash
forge test -vv
```

Expected output:

```
[PASS] test_WithoutDrosera_AttackSucceeds()
  [BASELINE] Attack succeeded - treasury drained to 0.

[PASS] test_Drosera_Mitigates_BeanstalkExploit()
  [TRAP FIRED] Governance flash-loan detected.
  [VAULT] Protocol paused. Attempting emergencyCommit...
  [SUCCESS] Treasury saved: 182000000000000000000000000

[PASS] test_NoFalsePositive_On_LargeStableHolder()
  [NO FALSE POSITIVE] Stable large holder correctly ignored.
```

---

## Deploy to Holesky Testnet

```bash
export RPC_URL="https://holesky.drpc.org"
export PRIVATE_KEY="0x..."
chmod +x deploy-holesky.sh
./deploy-holesky.sh
```

The script deploys all contracts, wires them together, and writes the final `drosera.toml`. Then run:

```bash
drosera apply
```

---

## Test Coverage

| Test                                        | What it proves                                                            |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| `test_WithoutDrosera_AttackSucceeds`        | Without the Trap, treasury drops to 0 (attack is real)                    |
| `test_Drosera_Mitigates_BeanstalkExploit`   | Trap fires → Vault pauses → `emergencyCommit()` reverts → treasury intact |
| `test_NoFalsePositive_On_LargeStableHolder` | Same large stake in both windows → Trap does NOT fire                     |

---

## Why This Matters

The same flash-acquire-then-govern attack vector exists in every on-chain protocol with a quorum threshold: Compound, Aave, MakerDAO, Uniswap governance. One Trap design, infinite protocols protected.
