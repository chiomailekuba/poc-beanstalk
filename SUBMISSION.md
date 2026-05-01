# Beanstalk Governance Flash-Loan Trap

## Operation Flytrap Resubmission

---

## Positioning

This project is a governance-risk detection and response demo inspired by the April 2022 Beanstalk exploit.
It demonstrates a production-inspired pattern where Drosera detects dangerous governance concentration across blocks and triggers a pause response when the protocol has a reaction window.

This submission no longer claims that a per-block Trap can interrupt a same-transaction atomic exploit.

---

## Attack Context (April 17, 2022)

| Item     | Detail                                                                                                             |
| -------- | ------------------------------------------------------------------------------------------------------------------ |
| Protocol | Beanstalk Farms (BEAN stablecoin)                                                                                  |
| Date     | April 17, 2022, block 14,602,790                                                                                   |
| Loss     | ~$182 million                                                                                                      |
| Vector   | Flash-loan reached governance supermajority, then `emergencyCommit()` executed in an atomic path to drain treasury |

Atomic same-transaction execution is the key boundary for this class of Trap.

---

## Architecture

```
BeanstalkTrap.collect()          reads on-chain governance snapshot
         |
         v
BeanstalkTrap.shouldRespond()    compares current block vs previous block
         |
         v
BeanstalkVault.executeResponse() authorized Drosera caller pauses protocol
```

---

## Reviewer-Driven Fixes Implemented

1. Correct Drosera snapshot ordering in `shouldRespond()`:
   - `data[0]` = current snapshot
   - `data[1]` = previous snapshot
2. `drosera.toml` now sets `block_sample_size = 2` to match two-snapshot logic.
3. `BeanstalkVault.executeResponse()` is now authorization-gated (`onlyDrosera`).
4. `BeanstalkMock.pause()` is now guardian-gated (`onlyPauseGuardian`).
5. Deployment script now wires pause guardian to the vault post-deploy.
6. Deployment defaults and docs updated to Hoodi testnet guidance.
7. Trap no longer requires constructor args; target wiring is one-time `configure(address)`.
8. Trap no longer depends on a known attacker address; it watches current top-holder concentration.
9. Protocol now enforces delayed emergency execution (`queueEmergencyCommit` -> `emergencyCommit`).

---

## Detection Invariant

Trap fires when all hold from previous to current snapshot:

1. Top-holder stake reaches at least 67% of total stake.
2. Top-holder stake increased in the latest block.
3. Top-holder commit is still in delay window (`readyBlock > block.number`).

If top-holder identity flips between snapshots, that transition is treated as suspicious takeover behavior.
This reduces false positives from static large holders while preserving takeover detection.

---

## Foundry Proof

**88 tests, 0 failures** — `test/BeanstalkMitigation.t.sol`

```
Suite result: ok. 88 passed; 0 failed; 0 skipped; finished in 245.79ms
```

| Section                          | Count | Focus                                                               |
| -------------------------------- | ----- | ------------------------------------------------------------------- |
| A – Integration smoke            | 5     | Baseline, mitigation, flip detection, false-positive, auth          |
| B – `collect()` units            | 11    | Output size, field correctness, zero-stalk guard                    |
| C – `shouldRespond()` boundaries | 16    | Empty inputs, supermajority boundary, delay window, paused snapshot |
| D – False-positive / safe paths  | 5     | Static large holder, small increase, sub-majority, zero change      |
| E – Top-holder transitions       | 4     | FLIP label, same-holder, benign overtake, zero-address prev         |
| F – Vault units                  | 13    | Auth gate, cooldown guard, event emission, immutables               |
| G – Trap configuration           | 8     | Owner, configure-once, zero-address guards, constants               |
| H – Mock access-control          | 15    | Guardian gate, supermajority gate, delay enforcement, atomic revert |
| I – Multi-block integration      | 6     | Full end-to-end, cooldown config, two-attacker flip scenario        |
| J – Fuzz                         | 5     | Junk safety (256 runs), determinism, below-supermajority invariant  |

Run:

```bash
forge test -vv
```

---

## Limits and Production Notes

1. This demo is bounded by block-level observation and cannot split an atomic transaction.
2. Real mitigation requires protocol-level controls such as execution delay, snapshot voting, and governance pause checks.
3. The mock remains intentionally simplified for deterministic testing and Trap logic demonstration.

---

## Files

```
src/
  interfaces/ITrap.sol        - Drosera ITrap interface
  BeanstalkMock.sol           - Simplified protected governance target
  BeanstalkTrap.sol           - Two-snapshot governance concentration detector
  BeanstalkVault.sol          - Authorized response contract
  BeanstalkAttacker.sol       - Attack simulator
test/
  BeanstalkMitigation.t.sol   - Foundry proof suite
drosera.toml                  - Drosera configuration
foundry.toml                  - Foundry configuration
  deploy-hoodi.sh               - Hoodi deployment script
```

---

## Deployed Contracts (Hoodi Testnet)

Chain ID: 560048 | Deployer: `0xc93BF33438C9c636fC49caFe1086C2C424507A15`

| Contract          | Address                                      | Tx Hash                                                              |
| ----------------- | -------------------------------------------- | -------------------------------------------------------------------- |
| BeanstalkMock     | `0xdAFd6bf6b9c32cd97c8185aFbc4dC361ABBFD83a` | `0x6b5efbf1369a4bc590874b5de26db32b30ce9f12a20dbd2aeba0143b8e83f606` |
| BeanstalkAttacker | `0x70C8B387C7139c810f716414e7df0Bfb54306C14` | `0xf1624978906d25350464a8fd7c953238d94ff65281a080ec984a364d0d9dac95` |
| BeanstalkVault    | `0x56c41dEE8266840C6A57747F02570B2B8669c661` | `0x262dcd222c31c834f0077259f051d0b0d9184375655ede97c5024f2692c160bf` |
| BeanstalkTrap     | `0xA734aCe09f5e05577A3E533Eee1D014Bd64f8CF7` | `0x354408fd366b7609b46b57052405fb0534811c358f5d2f1f959ee02fcca683ca` |

### Drosera Registration

| Item               | Value                                                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| TrapConfig address | `0x1f1cA37C905296df1cafFB63e2475df87be4909E`                                                                           |
| `drosera apply` tx | `0x4f5d302f25c26106927367aa6b5b911b110bf3e8a3808de1c3ce94802fe279b9`                                                   |
| Explorer           | [hoodi.etherscan.io](https://hoodi.etherscan.io/tx/0x4f5d302f25c26106927367aa6b5b911b110bf3e8a3808de1c3ce94802fe279b9) |
