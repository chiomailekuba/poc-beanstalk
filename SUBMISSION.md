# Beanstalk Governance Flash-Loan Trap

## Operation Flytrap Submission

---

## What This Is

A **Drosera Trap** that detects and mitigates the exact on-chain conditions that enabled the **Beanstalk Farms $182 M governance flash-loan attack** on April 17, 2022 — zero off-chain components required.

---

## The Attack (April 17, 2022)

| Item     | Detail                                                                                                                                     |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Protocol | Beanstalk Farms (BEAN stablecoin)                                                                                                          |
| Date     | April 17, 2022, block 14,602,790                                                                                                           |
| Loss     | ~$182 million                                                                                                                              |
| Vector   | Flash-loan acquired 67.08 % STALK governance supermajority in one block, then called `emergencyCommit()` to pass BIP-18 and drain treasury |

The root cause was a single atomic block in which an attacker:

1. Flash-borrowed enough STALK to exceed the 67 % governance threshold
2. Immediately called `emergencyCommit()` before the loan was repaid

No off-chain system could have reacted in time. Drosera is the only class of tool that can.

---

## Architecture

```
BeanstalkTrap.collect()          ← reads totalStalk + candidateStalk each block (pure on-chain)
         │
         ▼
BeanstalkTrap.shouldRespond()    ← compares block[N-1] vs block[N]:
                                    fires if candidateStalk jumped to ≥ 67 % of totalStalk
         │
         ▼
BeanstalkVault.executeResponse() ← calls protocol.pause() before emergencyCommit() can run
```

**No off-chain watcher. No oracle. No keeper. No Store contract.**  
`collect()` is a pure `view` function that reads directly from the protocol.

---

## Detection Invariant

The Trap fires when **both** conditions are true between consecutive blocks:

1. `candidateStalk[N] × 100 ≥ totalStalk[N] × 67` — supermajority reached
2. `candidateStalk[N] > candidateStalk[N-1]` — stake increased this block

Condition 2 prevents false positives on accounts that legitimately hold large STALK positions across many blocks (proven by Test 3).

---

## Foundry Proof

Three tests in `test/BeanstalkMitigation.t.sol`:

| Test                                        | Assertion                                                                 |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| `test_WithoutDrosera_AttackSucceeds`        | Without the Trap, treasury drops to 0                                     |
| `test_Drosera_Mitigates_BeanstalkExploit`   | Trap fires → Vault pauses → `emergencyCommit()` reverts → treasury intact |
| `test_NoFalsePositive_On_LargeStableHolder` | Same large stake in both windows → Trap does NOT fire                     |

Run with:

```bash
forge test -vv
```

---

## Addressing Reviewer Feedback

| Reviewer Criticism                                      | This Submission's Answer                                                                                          |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| "Too many off-chain dependencies"                       | Zero. `collect()` is a pure `view` read from the protocol. No backend, no oracle, no keeper.                      |
| "Too heuristic, not enough precision"                   | Exact 67 % supermajority threshold mirrors the real BIP-18 quorum requirement.                                    |
| "Needs one undeniable mitigation on a historic exploit" | April 17 2022, block 14,602,790. $182 M. Exact numbers reproduced in mock.                                        |
| "Needs a Foundry test proving it works"                 | Three tests. One proves the attack works unprotected. One proves Drosera stops it. One proves no false positives. |

---

## Files

```
src/
  interfaces/ITrap.sol        — Drosera ITrap interface
  BeanstalkMock.sol           — On-chain replica of vulnerable Beanstalk governance
  BeanstalkTrap.sol           — The Drosera Trap (implements ITrap)
  BeanstalkVault.sol          — Response contract (calls pause())
  BeanstalkAttacker.sol       — Simulates the April 2022 attacker
test/
  BeanstalkMitigation.t.sol   — Foundry proof (3 tests)
drosera.toml                  — Drosera network configuration
foundry.toml                  — Foundry build configuration
```

---

## Why This Wins

- **One real exploit. One exact mitigation. Zero ambiguity.**
- Pure on-chain detection — no off-chain attack surface.
- Passes every one of the reviewer's stated criteria.
- Different attack vector from other known PoCs in this cohort (Euler covered separately).
- The same Trap pattern generalises to any on-chain governance system with a quorum threshold.
