// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BeanstalkMock.sol";
import "../src/BeanstalkTrap.sol";
import "../src/BeanstalkVault.sol";
import "../src/BeanstalkAttacker.sol";

/**
 * @title BeanstalkMitigationTest
 * @notice Foundry proof that the BeanstalkTrap correctly detects and mitigates
 *         the April 17 2022 governance flash-loan attack.
 *
 * Three tests:
 *   1. test_WithoutDrosera_AttackSucceeds        — baseline: unprotected attack drains treasury
 *   2. test_Drosera_Mitigates_BeanstalkExploit   — Trap detects supermajority, Vault pauses,
 *                                                   treasury is saved
 *   3. test_NoFalsePositive_On_LargeStableHolder — same large stake in both windows → no fire
 */
contract BeanstalkMitigationTest is Test {
    BeanstalkMock internal protocol;
    BeanstalkTrap internal trap;
    BeanstalkVault internal vault;
    BeanstalkAttacker internal attacker;

    address internal constant ATTACKER_ADDR = address(0xBEEF);

    function setUp() public {
        protocol = new BeanstalkMock();
        attacker = new BeanstalkAttacker(address(protocol));
        trap = new BeanstalkTrap(address(protocol), address(attacker));
        vault = new BeanstalkVault(address(protocol));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1 — Baseline: without Drosera the attack succeeds
    // ─────────────────────────────────────────────────────────────────────────
    function test_WithoutDrosera_AttackSucceeds() public {
        uint256 treasuryBefore = protocol.treasury();
        assertGt(treasuryBefore, 0, "treasury should start non-zero");

        attacker.atomicAttack();

        assertEq(protocol.treasury(), 0, "treasury should be drained");
        console.log("[BASELINE] Attack succeeded - treasury drained to 0.");
        console.log("  Initial treasury :", treasuryBefore);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2 — Drosera detects and mitigates the exploit
    // ─────────────────────────────────────────────────────────────────────────
    function test_Drosera_Mitigates_BeanstalkExploit() public {
        uint256 initialTreasury = protocol.treasury();

        // Block N: collect normal state (no attacker stake yet)
        bytes memory snapshot1 = trap.collect();
        assertGt(snapshot1.length, 0, "snapshot1 should be non-empty");

        // Block N+1: attacker acquires flash votes
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();

        // Block N+1: collect post-attack snapshot
        bytes memory snapshot2 = trap.collect();
        assertGt(snapshot2.length, 0, "snapshot2 should be non-empty");

        // Feed both snapshots into shouldRespond
        bytes[] memory window = new bytes[](2);
        window[0] = snapshot1;
        window[1] = snapshot2;

        (bool trigger, bytes memory reason) = trap.shouldRespond(window);

        assertTrue(trigger, "Trap should fire on governance supermajority");
        console.log("[TRAP FIRED] Governance flash-loan detected.");

        // Drosera calls vault.executeResponse()
        vault.executeResponse(reason);
        assertTrue(
            protocol.paused(),
            "Protocol should be paused after vault response"
        );
        console.log("[VAULT] Protocol paused. Attempting emergencyCommit...");

        // Attacker tries to drain — must revert
        vm.expectRevert(bytes("BeanstalkMock: protocol is paused"));
        attacker.drainTreasury();

        // Treasury must be intact
        assertEq(
            protocol.treasury(),
            initialTreasury,
            "Treasury must remain intact"
        );
        console.log("[SUCCESS] Treasury saved:", initialTreasury);

        // Decode and log the incident report
        (
            string memory label,
            address suspect,
            uint256 currStake,
            uint256 prevStake,
            uint256 currTotal,
            uint256 atBlock,
            uint256 prevTotal
        ) = abi.decode(
                reason,
                (string, address, uint256, uint256, uint256, uint256, uint256)
            );

        console.log("  Incident :", label);
        console.log("  Suspect  :", suspect);
        console.log("  Stake was:", prevStake);
        console.log("  Stake now:", currStake);
        console.log("  Total now:", currTotal);
        console.log("  Prev total:", prevTotal);
        console.log("  At block :", atBlock);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3 — No false positive for a legitimately large existing holder
    // ─────────────────────────────────────────────────────────────────────────
    function test_NoFalsePositive_On_LargeStableHolder() public {
        // Seed attacker with a supermajority BEFORE both snapshots are taken
        // (i.e. the stake does NOT increase between block N and N+1)
        vm.prank(address(attacker));
        protocol.acquireFlashVotes();

        // Snapshot A — large stake already present
        bytes memory snapshotA = trap.collect();

        vm.roll(block.number + 1);

        // Snapshot B — same stake, no change
        bytes memory snapshotB = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = snapshotA;
        window[1] = snapshotB;

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger, "Trap must NOT fire when stake did not increase");
        console.log(
            "[NO FALSE POSITIVE] Stable large holder correctly ignored."
        );
    }
}
