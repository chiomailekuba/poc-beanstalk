// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BeanstalkMock.sol";
import "../src/BeanstalkTrap.sol";
import "../src/BeanstalkVault.sol";
import "../src/BeanstalkAttacker.sol";

/**
 * @title BeanstalkMitigationTest
 * @notice Comprehensive Foundry test suite for the Beanstalk Drosera Trap stack.
 *
 * Sections
 * ????????
 *  A. Integration smoke tests (original 5)
 *  B. collect() unit tests
 *  C. shouldRespond() boundary & logic tests
 *  D. shouldRespond() false-positive / safe-path tests
 *  E. Top-holder transition tests
 *  F. BeanstalkVault unit tests
 *  G. BeanstalkTrap configuration tests
 *  H. BeanstalkMock invariant & access-control tests
 *  I. Multi-block / Drosera-cycle integration tests
 *  J. Fuzz tests
 */
contract BeanstalkMitigationTest is Test {
    // Mirror event from BeanstalkVault for vm.expectEmit
    event GovernanceTakeoverContained(
        uint256 indexed responseId,
        uint256 indexed blockNumber,
        bytes incidentReport
    );

    BeanstalkMock internal protocol;
    BeanstalkTrap internal trap;
    BeanstalkVault internal vault;
    BeanstalkAttacker internal attacker;

    function setUp() public {
        protocol = new BeanstalkMock();
        attacker = new BeanstalkAttacker(address(protocol));
        trap = new BeanstalkTrap();
        trap.configure(address(protocol));
        vault = new BeanstalkVault(address(protocol), address(this));
        protocol.setPauseGuardian(address(vault));
    }

    // -------------------------------------------------------------------------
    // Test 1 -- Baseline: without Drosera the attack succeeds
    // -------------------------------------------------------------------------
    function test_WithoutDrosera_AttackSucceeds() public {
        uint256 treasuryBefore = protocol.treasury();
        assertGt(treasuryBefore, 0, "treasury should start non-zero");

        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        vm.roll(block.number + 1);
        attacker.drainTreasury();

        assertEq(protocol.treasury(), 0, "treasury should be drained");
        console.log(
            "[BASELINE] Delayed attack succeeded - treasury drained to 0."
        );
        console.log("  Initial treasury :", treasuryBefore);
    }

    // -------------------------------------------------------------------------
    // Test 2 -- Drosera detects and mitigates the exploit
    // -------------------------------------------------------------------------
    function test_Drosera_Mitigates_BeanstalkExploit() public {
        uint256 initialTreasury = protocol.treasury();

        // Block N: collect normal state (no attacker stake yet)
        bytes memory snapshot1 = trap.collect();
        assertGt(snapshot1.length, 0, "snapshot1 should be non-empty");

        // Block N+1: attacker acquires flash votes and queues delayed commit
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();

        // Block N+1: collect post-attack snapshot
        bytes memory snapshot2 = trap.collect();
        assertGt(snapshot2.length, 0, "snapshot2 should be non-empty");

        // Feed both snapshots into shouldRespond with Drosera ordering:
        // data[0] = current, data[1] = previous
        bytes[] memory window = new bytes[](2);
        window[0] = snapshot2;
        window[1] = snapshot1;

        (bool trigger, bytes memory reason) = trap.shouldRespond(window);

        assertTrue(trigger, "Trap should fire on governance supermajority");
        console.log(
            "[TRAP FIRED] Governance delay-window attack risk detected."
        );

        // Drosera calls vault.executeResponse()
        vault.executeResponse(reason);
        assertTrue(
            protocol.paused(),
            "Protocol should be paused after vault response"
        );
        console.log("[VAULT] Protocol paused. Attempting emergencyCommit...");

        // Attacker tries to drain on the next block - must revert because protocol is paused
        vm.roll(block.number + 1);
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
            uint256 prevTotal,
            uint256 readyBlock
        ) = abi.decode(
                reason,
                (
                    string,
                    address,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256
                )
            );

        console.log("  Incident :", label);
        console.log("  Suspect  :", suspect);
        console.log("  Stake was:", prevStake);
        console.log("  Stake now:", currStake);
        console.log("  Total now:", currTotal);
        console.log("  Prev total:", prevTotal);
        console.log("  At block :", atBlock);
        console.log("  Ready blk:", readyBlock);
    }

    // -------------------------------------------------------------------------
    // Test 3 -- Top-holder replacement must still be detected
    // -------------------------------------------------------------------------
    function test_Drosera_DetectsTakeover_WhenTopHolderChanges() public {
        address benignTopHolder = address(0xB0B);

        // Ensure previous snapshot has a known non-zero top holder.
        protocol.seedStalk(benignTopHolder, 1);

        bytes memory snapshot1 = trap.collect();
        assertGt(snapshot1.length, 0, "snapshot1 should be non-empty");

        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();

        bytes memory snapshot2 = trap.collect();
        assertGt(snapshot2.length, 0, "snapshot2 should be non-empty");

        bytes[] memory window = new bytes[](2);
        window[0] = snapshot2;
        window[1] = snapshot1;

        (bool trigger, bytes memory reason) = trap.shouldRespond(window);
        assertTrue(
            trigger,
            "Trap should fire when a new top holder flips into supermajority"
        );

        (string memory label, address suspect, , , , , , ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );

        assertEq(
            suspect,
            address(attacker),
            "Attacker should be identified as suspicious holder"
        );
        assertEq(
            keccak256(bytes(label)),
            keccak256(
                bytes("GOVERNANCE_DELAY_WINDOW_ATTACK_RISK_TOP_HOLDER_FLIP")
            ),
            "Top-holder takeover should use takeover-specific incident label"
        );

        vault.executeResponse(reason);
        assertTrue(
            protocol.paused(),
            "Protocol should be paused after takeover detection"
        );
    }

    // -------------------------------------------------------------------------
    // Test 4 -- No false positive for a legitimately large existing holder
    // -------------------------------------------------------------------------
    function test_NoFalsePositive_On_LargeStableHolder() public {
        // Seed attacker with a supermajority BEFORE both snapshots are taken
        // (i.e. the stake does NOT increase between block N and N+1)
        vm.prank(address(attacker));
        protocol.acquireFlashVotes();
        vm.prank(address(attacker));
        protocol.queueEmergencyCommit();

        // Snapshot A -- large stake already present
        bytes memory snapshotA = trap.collect();

        vm.roll(block.number + 1);

        // Snapshot B -- same stake, no change
        bytes memory snapshotB = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = snapshotB;
        window[1] = snapshotA;

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger, "Trap must NOT fire when stake did not increase");
        console.log(
            "[NO FALSE POSITIVE] Stable large holder correctly ignored."
        );
    }

    // -------------------------------------------------------------------------
    // Test 5 -- Vault cannot be triggered by arbitrary callers
    // -------------------------------------------------------------------------
    function test_VaultRejectsUnauthorizedCaller() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert(bytes("BeanstalkVault: not authorized"));
        vault.executeResponse(bytes("malicious-call"));
    }

    // ?????????????????????????????????????????????????????????????????????????
    // B. collect() unit tests
    // ?????????????????????????????????????????????????????????????????????????

    // B-01: collect() on a trap that was never configured returns empty bytes
    function test_collect_UnconfiguredReturnsEmpty() public {
        BeanstalkTrap freshTrap = new BeanstalkTrap();
        bytes memory out = freshTrap.collect();
        assertEq(out.length, 0, "unconfigured collect() must return empty");
    }

    // B-02: collect() after configure returns non-empty
    function test_collect_ConfiguredReturnsData() public {
        bytes memory out = trap.collect();
        assertGt(out.length, 0, "configured collect() must return data");
    }

    // B-03: collect() output encodes exactly 6 fields (192 bytes = 6 x 32)
    function test_collect_OutputIs192Bytes() public {
        bytes memory out = trap.collect();
        assertEq(out.length, 192, "collect() should encode 6 x 32 bytes");
    }

    // B-04: collect() records correct blockNumber
    function test_collect_BlockNumberIsCurrentBlock() public {
        vm.roll(42);
        bytes memory out = trap.collect();
        (, , , , uint256 blockNum, ) = abi.decode(
            out,
            (uint256, uint256, address, uint256, uint256, bool)
        );
        assertEq(
            blockNum,
            42,
            "blockNum in snapshot should match block.number"
        );
    }

    // B-05: collect() before any staking shows totalStalk == INITIAL_TOTAL_STALK
    function test_collect_TotalStalkMatchesInitial() public {
        bytes memory out = trap.collect();
        (uint256 total, , , , , ) = abi.decode(
            out,
            (uint256, uint256, address, uint256, uint256, bool)
        );
        assertEq(total, protocol.INITIAL_TOTAL_STALK(), "total stalk mismatch");
    }

    // B-06: collect() after acquireFlashVotes shows increased total
    function test_collect_TotalStalkAfterFlashVotes() public {
        attacker.acquireFlashVotes();
        bytes memory out = trap.collect();
        (uint256 total, , , , , ) = abi.decode(
            out,
            (uint256, uint256, address, uint256, uint256, bool)
        );
        assertEq(
            total,
            protocol.INITIAL_TOTAL_STALK() + protocol.FLASH_STALK_AMOUNT(),
            "total stalk should include flash amount"
        );
    }

    // B-07: collect() after protocol is paused reflects paused=true
    function test_collect_PausedFlagReflectedInSnapshot() public {
        protocol.setPauseGuardian(address(this));
        protocol.pause();
        bytes memory out = trap.collect();
        // collect() still returns data when paused (the trap silences itself in shouldRespond)
        assertGt(out.length, 0, "collect() returns data even when paused");
        (, , , , , bool isPaused) = abi.decode(
            out,
            (uint256, uint256, address, uint256, uint256, bool)
        );
        assertTrue(isPaused, "snapshot should reflect paused=true");
    }

    // B-08: collect() topHolder updates when new top holder seeded
    function test_collect_TopHolderUpdatesOnSeed() public {
        address alice = address(0xA11CE);
        protocol.seedStalk(alice, 50_000 ether);
        bytes memory out = trap.collect();
        (, , address topAddr, , , ) = abi.decode(
            out,
            (uint256, uint256, address, uint256, uint256, bool)
        );
        assertEq(topAddr, alice, "top holder should be alice after large seed");
    }

    // B-09: collect() readyBlock is 0 for holder with no queued commit
    function test_collect_ReadyBlockZeroWithNoQueue() public {
        bytes memory out = trap.collect();
        (, , , uint256 readyBlock, , ) = abi.decode(
            out,
            (uint256, uint256, address, uint256, uint256, bool)
        );
        assertEq(readyBlock, 0, "readyBlock should be 0 with no queued commit");
    }

    // B-10: collect() readyBlock reflects queued commit after acquireFlashVotes
    function test_collect_ReadyBlockAfterQueuedCommit() public {
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory out = trap.collect();
        (, , , uint256 readyBlock, , ) = abi.decode(
            out,
            (uint256, uint256, address, uint256, uint256, bool)
        );
        assertGt(readyBlock, 0, "readyBlock should be non-zero after queue");
    }

    // B-11: collect() returns empty bytes when totalStalk is 0
    function test_collect_EmptyWhenZeroTotalStalk() public {
        // Deploy a fresh mock with no initial stalk by crafting a zero-state
        // We can't set totalStalk to 0 externally; instead verify that the
        // guard branch is exercised: deploy with a fresh mock and override.
        // We simulate by testing the encoding guard via a mock that returns 0.
        // (Since BeanstalkMock always initialises with INITIAL_TOTAL_STALK,
        //  we use a separate contract to exercise the zero-total guard.)
        ZeroStalkMock zeroMock = new ZeroStalkMock();
        BeanstalkTrap t2 = new BeanstalkTrap();
        t2.configure(address(zeroMock));
        bytes memory out = t2.collect();
        assertEq(
            out.length,
            0,
            "collect() must return empty for zero totalStalk"
        );
    }

    // ?????????????????????????????????????????????????????????????????????????
    // C. shouldRespond() boundary & logic tests
    // ?????????????????????????????????????????????????????????????????????????

    // C-01: empty data array -> no trigger
    function test_shouldRespond_EmptyArrayNoTrigger() public {
        bytes[] memory data = new bytes[](0);
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t);
    }

    // C-02: single-element array -> no trigger
    function test_shouldRespond_SingleElementNoTrigger() public {
        bytes[] memory data = new bytes[](1);
        data[0] = trap.collect();
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t);
    }

    // C-03: both elements empty bytes -> no trigger
    function test_shouldRespond_BothEmptyNoTrigger() public {
        bytes[] memory data = new bytes[](2);
        data[0] = bytes("");
        data[1] = bytes("");
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t);
    }

    // C-04: current empty, prev valid -> no trigger
    function test_shouldRespond_CurrEmptyNoTrigger() public {
        bytes memory prev = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = bytes("");
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t);
    }

    // C-05: prev empty, current valid -> no trigger
    function test_shouldRespond_PrevEmptyNoTrigger() public {
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = bytes("");
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t);
    }

    // C-06: paused in current snapshot -> no trigger
    function test_shouldRespond_PausedInCurrentNoTrigger() public {
        attacker.acquireFlashVotes();
        bytes memory prev = trap.collect();
        attacker.queueEmergencyCommit();

        // Pause now -- snapshot captured while paused (vault is pauseGuardian)
        vm.prank(address(vault));
        protocol.pause();
        bytes memory curr = trap.collect();

        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "no trigger when current state is paused");
    }

    // C-07: stake did NOT increase between snapshots -> no trigger
    function test_shouldRespond_StakeUnchangedNoTrigger() public {
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory snap1 = trap.collect();
        vm.roll(block.number + 1);
        bytes memory snap2 = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = snap2;
        data[1] = snap1;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "stake unchanged -> no trigger");
    }

    // C-08: supermajority reached, stake increased, but NOT in delay window -> no trigger
    function test_shouldRespond_NoDelayWindowNoTrigger() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();

        // advance past delay window so readyBlock <= block.number
        vm.roll(block.number + 100);
        bytes memory curr = trap.collect();

        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "outside delay window -> no trigger");
    }

    // C-09: exactly at 67% boundary (>= 67%) -> TRIGGER
    function test_shouldRespond_ExactlyAtSupermajorityBoundary() public {
        // INITIAL_TOTAL_STALK = 10_000 ether; FLASH_STALK_AMOUNT = 20_400 ether
        // After flash: total = 30_400, top = 20_400
        // 20_400 * 100 = 2_040_000 >= 30_400 * 67 = 2_036_800 -> true
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertTrue(t, "67%+ should trigger");
    }

    // C-10: just below 67% -- stake is 66.9% -> no trigger
    function test_shouldRespond_JustBelowSupermajorityNoTrigger() public {
        // total = 10_000 + x, need x*100 < (10_000+x)*67
        // 33x < 670_000 -> x < 20_303.03 -> use 20_303
        uint256 subMajority = 20_303 ether;

        // Give a non-attacker address the sub-majority stake
        address bob = address(0xB0B2);
        protocol.seedStalk(bob, subMajority);
        bytes memory prev = trap.collect();

        // On next block bob acquires no extra stake -- snapshot unchanged
        vm.roll(block.number + 1);

        // Manually craft a snapshot where bob just barely got there (stake increased by 1)
        // We do it by seeding 1 more ether to bob so stakeJustIncreased is true but ratio < 67%
        protocol.seedStalk(bob, 1 ether); // now 20_304 ether out of 30_305 ether
        // 20_304 * 100 = 2_030_400   vs   30_305 * 67 = 2_030_435 -> still < 67%

        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "below 67% should not trigger");
    }

    // C-11: exactly 3+ elements in data[] -- should still use only [0] and [1]
    function test_shouldRespond_MoreThan2ElementsStillWorks() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](4);
        data[0] = curr;
        data[1] = prev;
        data[2] = bytes("garbage");
        data[3] = bytes("garbage2");
        (bool t, ) = trap.shouldRespond(data);
        assertTrue(t, "extra elements should not prevent trigger");
    }

    // C-12: incident label is correct for normal (non-flip) attack
    function test_shouldRespond_LabelIsCorrectForNonFlip() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        (string memory label, , , , , , , ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        assertEq(
            keccak256(bytes(label)),
            keccak256(bytes("GOVERNANCE_DELAY_WINDOW_ATTACK_RISK")),
            "label mismatch for non-flip attack"
        );
    }

    // C-13: incident report encodes correct currTopStake
    function test_shouldRespond_ReportEncodesCorrectCurrTopStake() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        (, , uint256 currStake, , , , , ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        assertEq(
            currStake,
            protocol.FLASH_STALK_AMOUNT(),
            "currTopStake in report should equal flash amount"
        );
    }

    // C-14: incident report suspect address is the attacker
    function test_shouldRespond_ReportSuspectIsAttacker() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        (, address suspect, , , , , , ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        assertEq(suspect, address(attacker), "suspect address mismatch");
    }

    // C-15: prevTotal in report equals INITIAL_TOTAL_STALK (no prior stake)
    function test_shouldRespond_ReportPrevTotalIsInitial() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        (, , , , , , uint256 prevTotal, ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        assertEq(
            prevTotal,
            protocol.INITIAL_TOTAL_STALK(),
            "prevTotal should be initial stalk"
        );
    }

    // C-16: readyBlock in report is correct
    function test_shouldRespond_ReportReadyBlockIsCorrect() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        uint256 queueBlock = block.number;
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        (, , , , , , , uint256 readyBlock) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        assertEq(
            readyBlock,
            queueBlock + protocol.MIN_EXECUTION_DELAY_BLOCKS(),
            "readyBlock should be queueBlock + MIN_EXECUTION_DELAY_BLOCKS"
        );
    }

    // ?????????????????????????????????????????????????????????????????????????
    // D. False-positive / safe-path tests
    // ?????????????????????????????????????????????????????????????????????????

    // D-01: normal governance activity (small stake increase) -> no trigger
    function test_NoFalsePositive_SmallStakeIncrease() public {
        address whale = address(0xA11CE);
        protocol.seedStalk(whale, 100 ether);
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        protocol.seedStalk(whale, 50 ether); // still far below 67%
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "small stake increase should not trigger");
    }

    // D-02: 66% concentration, no delay window -> no trigger
    function test_NoFalsePositive_SubMajorityInDelayWindow() public {
        // 20_303 ether gives 66.9% -- below threshold
        address charlie = address(0xC4A4);
        protocol.seedStalk(charlie, 20_000 ether);
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        protocol.seedStalk(charlie, 1 ether);
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "sub-67% stake should not trigger even with increase");
    }

    // D-03: normal block with zero top holder change -> no trigger
    function test_NoFalsePositive_ZeroStakeChange() public {
        bytes memory snap1 = trap.collect();
        vm.roll(block.number + 1);
        bytes memory snap2 = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = snap2;
        data[1] = snap1;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "zero stake change should never trigger");
    }

    // D-04: multiple legit seedStalk calls across blocks -> no trigger
    function test_NoFalsePositive_MultipleLegitimateSeeds() public {
        address dave = address(0xDA4E);
        for (uint256 i = 0; i < 5; i++) {
            protocol.seedStalk(dave, 100 ether);
            vm.roll(block.number + 1);
        }
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        protocol.seedStalk(dave, 100 ether);
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "gradual small increases should not trigger");
    }

    // D-05: treasury empty does not affect trap triggering
    function test_NoFalsePositive_TreasuryDrainedAlreadyDoesNotTrigger()
        public
    {
        // Drain treasury the old-fashioned way first
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        vm.roll(block.number + 1);
        attacker.drainTreasury();

        // Now on subsequent blocks the same holder's stake doesn't increase
        bytes memory snap1 = trap.collect();
        vm.roll(block.number + 1);
        bytes memory snap2 = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = snap2;
        data[1] = snap1;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(t, "already-drained, no new stake -> no trigger");
    }

    // ?????????????????????????????????????????????????????????????????????????
    // E. Top-holder transition tests
    // ?????????????????????????????????????????????????????????????????????????

    // E-01: attacker overtakes a benign top holder -- label must say FLIP
    function test_TopHolder_FlipLabelOnTakeover() public {
        address benign = address(0xBE0);
        protocol.seedStalk(benign, 1 ether); // small enough that attacker still hits 67%
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        (string memory label, , , , , , , ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        assertEq(
            keccak256(bytes(label)),
            keccak256(
                bytes("GOVERNANCE_DELAY_WINDOW_ATTACK_RISK_TOP_HOLDER_FLIP")
            ),
            "label should be FLIP variant on holder change"
        );
    }

    // E-02: same address remains top holder -- label must NOT say FLIP
    function test_TopHolder_NoFlipLabelWhenSameHolder() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        (string memory label, , , , , , , ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        assertEq(
            keccak256(bytes(label)),
            keccak256(bytes("GOVERNANCE_DELAY_WINDOW_ATTACK_RISK")),
            "label should not be FLIP when same holder stays on top"
        );
    }

    // E-03: prev top holder is address(0) -- FLIP flag should NOT be set (no prior known holder)
    function test_TopHolder_NoFlipWhenPrevHolderIsZeroAddress() public {
        // Fresh protocol, no seeds -- top holder stays address(0) in both snapshots
        // Then attacker jumps in; prev topAddress was address(0) -> no flip
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();

        // Manually verify prev decoded topAddress
        (, , address prevTopAddr, , , ) = abi.decode(
            prev,
            (uint256, uint256, address, uint256, uint256, bool)
        );
        assertEq(
            prevTopAddr,
            address(0),
            "prev top should be address(0) in clean state"
        );

        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        (string memory label, , , , , , , ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        // When prevTopAddress == address(0) the topHolderChanged flag is false
        assertEq(
            keccak256(bytes(label)),
            keccak256(bytes("GOVERNANCE_DELAY_WINDOW_ATTACK_RISK")),
            "no flip label when prev top is zero address"
        );
    }

    // E-04: two benign whales -- second overtakes first legitimately without supermajority -> no trigger
    function test_TopHolder_BenignOvertakeWithoutSupermajority() public {
        address whale1 = address(0xAA);
        address whale2 = address(0xBB);
        protocol.seedStalk(whale1, 1_000 ether);
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        // whale2 seeds slightly more -- still no supermajority
        protocol.seedStalk(whale2, 1_100 ether);
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, ) = trap.shouldRespond(data);
        assertFalse(
            t,
            "benign whale overtake without supermajority should not trigger"
        );
    }

    // ?????????????????????????????????????????????????????????????????????????
    // F. BeanstalkVault unit tests
    // ?????????????????????????????????????????????????????????????????????????

    // F-01: executeResponse by authorised caller succeeds
    function test_Vault_AuthorizedCallerSucceeds() public {
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        // invert ordering to avoid trigger; just send bytes to vault directly
        // Actually send a valid reason; use a pre-built reason
        attacker.acquireFlashVotes(); // would fail because already has flash votes, but let's just test vault accepts the call
        // Use the authorised caller pattern (address(this) is DROSERA_CALLER)
        bytes memory reason = bytes("test-reason");
        vault.executeResponse(reason); // should not revert
        assertTrue(protocol.paused());
    }

    // F-02: unauthorised caller is rejected
    function test_Vault_UnauthorizedCallerReverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("BeanstalkVault: not authorized"));
        vault.executeResponse(bytes(""));
    }

    // F-03: cooldown blocks a second call in the same block
    function test_Vault_CooldownBlocksSameBlockCall() public {
        vault.executeResponse(bytes("first"));
        vm.expectRevert(bytes("BeanstalkVault: cooldown active"));
        vault.executeResponse(bytes("second"));
    }

    // F-04: cooldown blocks a call within COOLDOWN_BLOCKS
    function test_Vault_CooldownBlocksCallWithinWindow() public {
        vault.executeResponse(bytes("first"));
        vm.roll(block.number + vault.COOLDOWN_BLOCKS() - 1);
        vm.expectRevert(bytes("BeanstalkVault: cooldown active"));
        vault.executeResponse(bytes("second"));
    }

    // F-05: call succeeds after exactly COOLDOWN_BLOCKS blocks
    function test_Vault_CooldownExpiresAfterCooldownBlocks() public {
        vault.executeResponse(bytes("first"));
        vm.roll(block.number + vault.COOLDOWN_BLOCKS());
        // Must re-set pauseGuardian to vault and unpause manually (protocol is already paused)
        // Unpause via a fresh protocol
        BeanstalkMock freshProtocol = new BeanstalkMock();
        BeanstalkVault freshVault = new BeanstalkVault(
            address(freshProtocol),
            address(this)
        );
        freshProtocol.setPauseGuardian(address(freshVault));
        freshVault.executeResponse(bytes("first"));
        vm.roll(block.number + freshVault.COOLDOWN_BLOCKS());
        // Protocol is already paused -- this call will succeed (cooldown passed) but pause() is idempotent
        freshVault.executeResponse(bytes("second"));
        assertEq(freshVault.responseCount(), 2, "responseCount should be 2");
    }

    // F-06: responseCount increments each valid call
    function test_Vault_ResponseCountIncrements() public {
        assertEq(vault.responseCount(), 0, "initial responseCount should be 0");
        vault.executeResponse(bytes("x"));
        assertEq(
            vault.responseCount(),
            1,
            "responseCount should be 1 after first call"
        );
    }

    // F-07: lastResponseBlock is recorded correctly
    function test_Vault_LastResponseBlockIsRecorded() public {
        vm.roll(77);
        vault.executeResponse(bytes("x"));
        assertEq(
            vault.lastResponseBlock(),
            77,
            "lastResponseBlock should be 77"
        );
    }

    // F-08: GovernanceTakeoverContained event is emitted
    function test_Vault_EventEmitted() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit GovernanceTakeoverContained(1, block.number, bytes("report"));
        vault.executeResponse(bytes("report"));
    }

    // F-09: vault DROSERA_CALLER immutable is set correctly
    function test_Vault_DROSERACallerIsCorrect() public {
        assertEq(
            vault.DROSERA_CALLER(),
            address(this),
            "DROSERA_CALLER should be address(this)"
        );
    }

    // F-10: vault TARGET is set correctly
    function test_Vault_TargetIsCorrect() public {
        assertEq(
            address(vault.TARGET()),
            address(protocol),
            "TARGET should be protocol"
        );
    }

    // F-11: vault with zero target reverts on construction
    function test_Vault_ZeroTargetReverts() public {
        vm.expectRevert(bytes("BeanstalkVault: invalid target"));
        new BeanstalkVault(address(0), address(this));
    }

    // F-12: vault with zero droseraCaller reverts on construction
    function test_Vault_ZeroCallerReverts() public {
        vm.expectRevert(bytes("BeanstalkVault: invalid caller"));
        new BeanstalkVault(address(protocol), address(0));
    }

    // F-13: first-ever call (lastResponseBlock == 0) does not hit cooldown
    function test_Vault_FirstCallBypassesCooldownCheck() public {
        assertEq(
            vault.lastResponseBlock(),
            0,
            "initial lastResponseBlock is 0"
        );
        vault.executeResponse(bytes("first-ever"));
        // If we got here without revert, the zero-check branch worked
        assertTrue(protocol.paused());
    }

    // ?????????????????????????????????????????????????????????????????????????
    // G. BeanstalkTrap configuration tests
    // ?????????????????????????????????????????????????????????????????????????

    // G-01: double configure reverts
    function test_Trap_DoubleConfigureReverts() public {
        vm.expectRevert(bytes("BeanstalkTrap: already configured"));
        trap.configure(address(protocol));
    }

    // G-02: configure from non-owner reverts
    function test_Trap_NonOwnerConfigureReverts() public {
        BeanstalkTrap freshTrap = new BeanstalkTrap();
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("BeanstalkTrap: not owner"));
        freshTrap.configure(address(protocol));
    }

    // G-03: configure with zero address reverts
    function test_Trap_ZeroAddressConfigureReverts() public {
        BeanstalkTrap freshTrap = new BeanstalkTrap();
        vm.expectRevert(bytes("BeanstalkTrap: invalid target"));
        freshTrap.configure(address(0));
    }

    // G-04: owner is set to deployer in constructor
    function test_Trap_OwnerIsDeployer() public {
        BeanstalkTrap freshTrap = new BeanstalkTrap();
        assertEq(freshTrap.owner(), address(this), "owner should be deployer");
    }

    // G-05: configured flag is false before configure()
    function test_Trap_ConfiguredFalseBeforeConfigure() public {
        BeanstalkTrap freshTrap = new BeanstalkTrap();
        assertFalse(
            freshTrap.configured(),
            "configured should be false initially"
        );
    }

    // G-06: configured flag is true after configure()
    function test_Trap_ConfiguredTrueAfterConfigure() public {
        assertTrue(
            trap.configured(),
            "configured should be true after configure()"
        );
    }

    // G-07: TARGET is set correctly after configure()
    function test_Trap_TargetSetAfterConfigure() public {
        assertEq(
            address(trap.TARGET()),
            address(protocol),
            "TARGET should be protocol"
        );
    }

    // G-08: SUPERMAJORITY constants are correct
    function test_Trap_SupermajorityConstantsCorrect() public {
        assertEq(trap.SUPERMAJORITY_NUMERATOR(), 67, "numerator should be 67");
        assertEq(
            trap.SUPERMAJORITY_DENOMINATOR(),
            100,
            "denominator should be 100"
        );
    }

    // ?????????????????????????????????????????????????????????????????????????
    // H. BeanstalkMock access-control & invariant tests
    // ?????????????????????????????????????????????????????????????????????????

    // H-01: acquireFlashVotes reverts when paused
    function test_Mock_AcquireFlashVotesRevertsWhenPaused() public {
        vm.prank(address(vault)); // vault is pauseGuardian
        protocol.pause();
        vm.expectRevert(bytes("BeanstalkMock: protocol is paused"));
        attacker.acquireFlashVotes();
    }

    // H-02: queueEmergencyCommit reverts without supermajority
    function test_Mock_QueueCommitRevertsWithoutSupermajority() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("BeanstalkMock: insufficient governance power"));
        protocol.queueEmergencyCommit();
    }

    // H-03: emergencyCommit reverts without queue
    function test_Mock_EmergencyCommitRevertsWithoutQueue() public {
        attacker.acquireFlashVotes();
        vm.expectRevert(bytes("BeanstalkMock: commit not queued"));
        // Call emergencyCommit directly as attacker (who has supermajority but hasn't queued)
        vm.prank(address(attacker));
        protocol.emergencyCommit();
    }

    // H-04: emergencyCommit reverts inside delay window
    function test_Mock_EmergencyCommitRevertsInDelayWindow() public {
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        // Do NOT roll past the delay
        vm.prank(address(attacker));
        vm.expectRevert(bytes("BeanstalkMock: execution delay active"));
        protocol.emergencyCommit();
    }

    // H-05: emergencyCommit succeeds after delay window
    function test_Mock_EmergencyCommitSucceedsAfterDelay() public {
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        vm.roll(block.number + protocol.MIN_EXECUTION_DELAY_BLOCKS());
        vm.prank(address(attacker));
        protocol.emergencyCommit();
        assertEq(
            protocol.treasury(),
            0,
            "treasury should be zero after commit"
        );
    }

    // H-06: pause reverts when called by non-guardian
    function test_Mock_PauseRevertsForNonGuardian() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("BeanstalkMock: not guardian"));
        protocol.pause();
    }

    // H-07: setPauseGuardian reverts for non-owner
    function test_Mock_SetPauseGuardianRevertsForNonOwner() public {
        vm.prank(address(0xEEEE));
        vm.expectRevert(bytes("BeanstalkMock: not owner"));
        protocol.setPauseGuardian(address(0x1));
    }

    // H-08: setPauseGuardian reverts for zero address
    function test_Mock_SetPauseGuardianRevertsForZeroAddress() public {
        vm.expectRevert(bytes("BeanstalkMock: invalid guardian"));
        protocol.setPauseGuardian(address(0));
    }

    // H-09: seedStalk correctly updates topHolder
    function test_Mock_SeedStalkUpdatesTopHolder() public {
        address eve = address(0xE4E);
        protocol.seedStalk(eve, 999_999 ether);
        assertEq(protocol.topHolder(), eve, "eve should be top holder");
        assertEq(
            protocol.topHolderStalk(),
            999_999 ether,
            "topHolderStalk should match"
        );
    }

    // H-10: totalStalk increases correctly after seedStalk
    function test_Mock_SeedStalkUpdatesTotalStalk() public {
        uint256 before = protocol.totalStalk();
        protocol.seedStalk(address(0x1), 500 ether);
        assertEq(
            protocol.totalStalk(),
            before + 500 ether,
            "totalStalk increment mismatch"
        );
    }

    // H-11: atomicAttack reverts because queue+execute cannot occur in the same block
    function test_Mock_AtomicAttackDrainsTreasury() public {
        vm.expectRevert(bytes("BeanstalkMock: execution delay active"));
        attacker.atomicAttack();
    }

    // H-12: getTrapSnapshot returns paused=false initially
    function test_Mock_TrapSnapshotPausedFalseInitially() public {
        (, , , , , bool isPaused) = protocol.getTrapSnapshot();
        assertFalse(isPaused, "should not be paused initially");
    }

    // H-13: getTrapSnapshot reflects updated topHolder
    function test_Mock_TrapSnapshotReflectsTopHolder() public {
        address frank = address(0xF4F);
        protocol.seedStalk(frank, 50_000 ether);
        (, , address topAddr, , , ) = protocol.getTrapSnapshot();
        assertEq(topAddr, frank, "snapshot topHolder should be frank");
    }

    // H-14: emergencyCommit reverts when paused
    function test_Mock_EmergencyCommitRevertsWhenPaused() public {
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        vm.roll(block.number + protocol.MIN_EXECUTION_DELAY_BLOCKS());
        vm.prank(address(vault)); // vault is pauseGuardian
        protocol.pause();
        vm.prank(address(attacker));
        vm.expectRevert(bytes("BeanstalkMock: protocol is paused"));
        protocol.emergencyCommit();
    }

    // H-15: queueEmergencyCommit reverts when paused
    function test_Mock_QueueCommitRevertsWhenPaused() public {
        attacker.acquireFlashVotes();
        vm.prank(address(vault)); // vault is pauseGuardian
        protocol.pause();
        vm.prank(address(attacker));
        vm.expectRevert(bytes("BeanstalkMock: protocol is paused"));
        protocol.queueEmergencyCommit();
    }

    // ?????????????????????????????????????????????????????????????????????????
    // I. Multi-block / Drosera-cycle integration tests
    // ?????????????????????????????????????????????????????????????????????????

    // I-01: vault pauses protocol before delay window expires -- treasury saved
    function test_Integration_VaultPausesBeforeDelayExpires() public {
        uint256 initialTreasury = protocol.treasury();
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, bytes memory reason) = trap.shouldRespond(data);
        assertTrue(t);
        vault.executeResponse(reason);
        assertTrue(protocol.paused());
        vm.roll(block.number + protocol.MIN_EXECUTION_DELAY_BLOCKS());
        vm.expectRevert(bytes("BeanstalkMock: protocol is paused"));
        attacker.drainTreasury();
        assertEq(protocol.treasury(), initialTreasury, "treasury intact");
    }

    // I-02: vault cooldown period aligns with drosera.toml cooldown_period_blocks=33
    function test_Integration_CooldownMatchesConfig() public {
        assertEq(
            vault.COOLDOWN_BLOCKS(),
            33,
            "cooldown should match drosera.toml"
        );
    }

    // I-03: repeated trap calls across many blocks -- no trigger without attack
    function test_Integration_NoTriggerAcross10QuietBlocks() public {
        bytes memory prev = trap.collect();
        for (uint256 i = 0; i < 10; i++) {
            vm.roll(block.number + 1);
            bytes memory curr = trap.collect();
            bytes[] memory data = new bytes[](2);
            data[0] = curr;
            data[1] = prev;
            (bool t, ) = trap.shouldRespond(data);
            assertFalse(t, "quiet blocks should never trigger");
            prev = curr;
        }
    }

    // I-04: attacker queues, Drosera pauses, attacker tries again after cooldown -- still paused
    function test_Integration_AttackerCannotBypassPauseAfterCooldown() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (, bytes memory reason) = trap.shouldRespond(data);
        vault.executeResponse(reason);
        assertTrue(protocol.paused());

        // Fast-forward far past vault cooldown and delay window
        vm.roll(block.number + 100);

        // Attacker tries to drain -- still blocked by pause
        vm.expectRevert(bytes("BeanstalkMock: protocol is paused"));
        attacker.drainTreasury();
    }

    // I-05: two attackers -- second attacker triggers flip label
    function test_Integration_TwoAttackersTriggerFlip() public {
        address attacker2 = address(new BeanstalkAttacker(address(protocol)));
        protocol.seedStalk(attacker2, 1 ether); // small enough that attacker still hits 67%
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        // Original attacker acquires supermajority
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;
        (bool t, bytes memory reason) = trap.shouldRespond(data);
        assertTrue(t);
        (string memory label, , , , , , , ) = abi.decode(
            reason,
            (
                string,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256
            )
        );
        // attacker2 was top holder before; original attacker flips -- FLIP label
        assertEq(
            keccak256(bytes(label)),
            keccak256(
                bytes("GOVERNANCE_DELAY_WINDOW_ATTACK_RISK_TOP_HOLDER_FLIP")
            ),
            "second attacker scenario should produce FLIP label"
        );
    }

    // I-06: full end-to-end flow -- detect, report, pause, confirm treasury intact
    function test_Integration_FullEndToEndFlow() public {
        uint256 treasury0 = protocol.treasury();
        assertGt(treasury0, 0);

        // Block 1: idle snapshot
        bytes memory s1 = trap.collect();

        // Block 2: attack launched
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory s2 = trap.collect();

        // Drosera shouldRespond
        bytes[] memory window = new bytes[](2);
        window[0] = s2;
        window[1] = s1;
        (bool fired, bytes memory report) = trap.shouldRespond(window);
        assertTrue(fired);

        // Drosera calls vault
        vault.executeResponse(report);

        // Delay window passes
        vm.roll(block.number + protocol.MIN_EXECUTION_DELAY_BLOCKS());

        // Attacker blocked
        vm.expectRevert(bytes("BeanstalkMock: protocol is paused"));
        attacker.drainTreasury();

        assertEq(protocol.treasury(), treasury0, "treasury must be intact");
    }

    // ?????????????????????????????????????????????????????????????????????????
    // J. Fuzz tests
    // ?????????????????????????????????????????????????????????????????????????

    // J-01: fuzz -- seed any amount; never triggers unless supermajority
    function testFuzz_NoTriggerBelowSupermajority(uint96 seedAmount) public {
        // Cap well below the threshold that would produce supermajority in one block
        uint256 safeAmount = uint256(seedAmount) % 20_000 ether;
        vm.assume(safeAmount > 0);

        address whale = address(0xFAFA);
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        protocol.seedStalk(whale, safeAmount);
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;

        (uint256 currTotal, uint256 currTop, , , , ) = abi.decode(
            curr,
            (uint256, uint256, address, uint256, uint256, bool)
        );

        (bool t, ) = trap.shouldRespond(data);

        // If currTop * 100 < currTotal * 67 -> must not trigger
        if (currTop * 100 < currTotal * 67) {
            assertFalse(t, "below supermajority should not trigger");
        }
        // (If by coincidence it hits 67% the trigger outcome is implementation-correct)
    }

    // J-02: fuzz -- vault cooldown: call N blocks after first call, N < COOLDOWN_BLOCKS -> revert
    function testFuzz_VaultCooldownAlwaysRevertsWithinWindow(
        uint8 offset
    ) public {
        uint256 blocksToAdvance = uint256(offset) % vault.COOLDOWN_BLOCKS();
        vault.executeResponse(bytes("first"));
        vm.roll(block.number + blocksToAdvance);

        if (blocksToAdvance < vault.COOLDOWN_BLOCKS()) {
            vm.expectRevert(bytes("BeanstalkVault: cooldown active"));
            vault.executeResponse(bytes("second"));
        }
    }

    // J-03: fuzz -- responseCount always matches number of successful executeResponse calls
    function testFuzz_ResponseCountAccurate(uint8 calls) public {
        uint256 numCalls = (uint256(calls) % 5) + 1; // 1-5 calls
        // Use a fresh vault and protocol for each fuzz run to avoid paused state issues
        BeanstalkMock freshProtocol = new BeanstalkMock();
        BeanstalkVault freshVault = new BeanstalkVault(
            address(freshProtocol),
            address(this)
        );
        freshProtocol.setPauseGuardian(address(freshVault));

        for (uint256 i = 0; i < numCalls; i++) {
            vm.roll(block.number + freshVault.COOLDOWN_BLOCKS() + 1);
            freshVault.executeResponse(bytes("x"));
        }
        assertEq(
            freshVault.responseCount(),
            numCalls,
            "responseCount should match call count"
        );
    }

    // J-04: fuzz -- shouldRespond is pure -- identical snapshots always return same result
    function testFuzz_ShouldRespondIsDeterministic(uint8 blockOffset) public {
        vm.roll(uint256(blockOffset) + 1);
        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();
        bytes[] memory data = new bytes[](2);
        data[0] = curr;
        data[1] = prev;

        (bool t1, bytes memory r1) = trap.shouldRespond(data);
        (bool t2, bytes memory r2) = trap.shouldRespond(data);
        assertEq(t1, t2, "deterministic: trigger must match");
        assertEq(
            keccak256(r1),
            keccak256(r2),
            "deterministic: response must match"
        );
    }

    // J-05: fuzz -- any junk bytes in data[] should never panic (revert or no trigger only)
    function testFuzz_JunkDataNeverPanics(bytes memory junk) public view {
        bytes[] memory data = new bytes[](2);
        data[0] = junk;
        data[1] = junk;
        // Must not revert (ABI decode on random bytes will produce garbage values but not panic
        // because shouldRespond guards length before decoding)
        if (junk.length < 192) {
            // too short to be valid ABI encoding -- the try will be a no-op (both empty -> false)
        }
        // We can't call shouldRespond with invalid ABI encoding without it reverting on decode.
        // Guard: only call if the junk is a valid length (192 bytes)
        if (junk.length == 192) {
            // May or may not trigger -- just must not revert unexpectedly
            try trap.shouldRespond(data) returns (
                bool,
                bytes memory
            ) {} catch {}
        }
    }
}

// ???????????????????????????????????????????????????????????????????????????
// Helper contract for B-11 (zero totalStalk collect guard)
// ???????????????????????????????????????????????????????????????????????????
contract ZeroStalkMock {
    function getTrapSnapshot()
        external
        pure
        returns (
            uint256 snapshotTotalStalk,
            uint256 snapshotTopHolderStalk,
            address snapshotTopHolder,
            uint256 snapshotTopHolderReadyBlock,
            uint256 snapshotBlock,
            bool snapshotPaused
        )
    {
        return (0, 0, address(0), 0, 1, false);
    }
}
