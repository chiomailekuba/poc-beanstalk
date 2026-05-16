// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BeanstalkAttacker.sol";
import "../src/BeanstalkMock.sol";
import "../src/BeanstalkTrapV2.sol";
import "../src/BeanstalkTypes.sol";
import "../src/BeanstalkVaultV2.sol";

contract TrapHarness is BeanstalkTrapV2 {
    address private immutable target_;

    constructor(address targetAddress) {
        target_ = targetAddress;
    }

    function _target() internal view override returns (address) {
        return target_;
    }
}

contract RevertingSnapshotMock {
    function getTrapSnapshot()
        external
        pure
        returns (uint256, uint256, address, uint256, uint256, bool)
    {
        revert("snapshot failure");
    }
}

contract NoPauseTarget {
    bool public paused;

    function pause() external {
        // Intentionally does not flip paused.
    }
}

contract BeanstalkMitigationV2Test is Test {
    BeanstalkMock internal protocol;
    BeanstalkAttacker internal attacker;
    TrapHarness internal trap;
    BeanstalkVaultV2 internal vault;

    function setUp() public {
        protocol = new BeanstalkMock();
        attacker = new BeanstalkAttacker(address(protocol));
        trap = new TrapHarness(address(protocol));
        vault = new BeanstalkVaultV2(address(protocol), address(this), 33);
        protocol.setPauseGuardian(address(vault));
    }

    function _decodeCollect(
        bytes memory raw
    ) internal pure returns (BeanstalkTypes.CollectOutput memory) {
        return abi.decode(raw, (BeanstalkTypes.CollectOutput));
    }

    function _validIncident()
        internal
        view
        returns (BeanstalkTypes.Incident memory)
    {
        return
            BeanstalkTypes.Incident({
                invariantId: BeanstalkTypes.INVARIANT_ID,
                target: address(protocol),
                suspect: address(attacker),
                currentTopStake: 20_400 ether,
                previousTopStake: 0,
                currentTotalStalk: 30_400 ether,
                previousTotalStalk: 10_000 ether,
                currentBlock: block.number,
                previousBlock: block.number - 1,
                readyBlock: block.number + 1,
                reason: BeanstalkTypes.REASON_SUPERMAJORITY_DELAY_WINDOW
            });
    }

    function test_collect_ReturnsStatusTargetMissing_WhenTargetHasNoCode()
        public
    {
        BeanstalkTrapV2 staticTrap = new BeanstalkTrapV2();
        BeanstalkTypes.CollectOutput memory out = _decodeCollect(
            staticTrap.collect()
        );

        assertEq(out.schemaVersion, 1);
        assertEq(out.status, BeanstalkTypes.STATUS_TARGET_MISSING);
        assertEq(
            out.target,
            address(0x000000000000000000000000000000000000bEEF)
        );
    }

    function test_collect_ReturnsStatusReadFailed_WhenSnapshotReverts() public {
        RevertingSnapshotMock bad = new RevertingSnapshotMock();
        TrapHarness badTrap = new TrapHarness(address(bad));
        BeanstalkTypes.CollectOutput memory out = _decodeCollect(
            badTrap.collect()
        );

        assertEq(out.status, BeanstalkTypes.STATUS_READ_FAILED);
    }

    function test_shouldAlert_FiresForStatusReadFailed() public {
        RevertingSnapshotMock bad = new RevertingSnapshotMock();
        TrapHarness badTrap = new TrapHarness(address(bad));

        bytes[] memory window = new bytes[](1);
        window[0] = badTrap.collect();

        (bool alerting, ) = badTrap.shouldAlert(window);
        assertTrue(alerting);
    }

    function test_shouldAlert_FiresForStatusTargetMissing() public {
        BeanstalkTrapV2 staticTrap = new BeanstalkTrapV2();

        bytes[] memory window = new bytes[](1);
        window[0] = staticTrap.collect();

        (bool alerting, ) = staticTrap.shouldAlert(window);
        assertTrue(alerting);
    }

    function test_shouldAlert_FiresForStatusZeroTotalStalk() public {
        BeanstalkTypes.CollectOutput memory out;
        out.schemaVersion = 1;
        out.status = BeanstalkTypes.STATUS_ZERO_TOTAL_STALK;
        out.invariantId = BeanstalkTypes.INVARIANT_ID;
        out.target = address(protocol);

        bytes[] memory window = new bytes[](1);
        window[0] = abi.encode(out);

        (bool alerting, ) = trap.shouldAlert(window);
        assertTrue(alerting);
    }

    function test_shouldRespond_Malformed1ByteCurrent_DoesNotRevert() public {
        bytes[] memory window = new bytes[](2);
        window[0] = hex"00";
        window[1] = trap.collect();

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_shouldRespond_Malformed191Bytes_DoesNotRevert() public {
        bytes[] memory window = new bytes[](2);
        window[0] = new bytes(191);
        window[1] = trap.collect();

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_shouldRespond_Malformed193Bytes_DoesNotRevert() public {
        bytes[] memory window = new bytes[](2);
        window[0] = new bytes(193);
        window[1] = trap.collect();

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_shouldRespond_RejectsNonContiguousSamples() public {
        bytes memory prev = trap.collect();
        vm.roll(block.number + 2);
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_shouldRespond_RejectsMismatchedTarget() public {
        bytes memory prevRaw = trap.collect();
        vm.roll(block.number + 1);
        bytes memory currRaw = trap.collect();

        BeanstalkTypes.CollectOutput memory prev = _decodeCollect(prevRaw);
        prev.target = address(0xAA);

        bytes[] memory window = new bytes[](2);
        window[0] = currRaw;
        window[1] = abi.encode(prev);

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_shouldRespond_RejectsWrongInvariant() public {
        bytes memory prevRaw = trap.collect();
        vm.roll(block.number + 1);
        bytes memory currRaw = trap.collect();

        BeanstalkTypes.CollectOutput memory prev = _decodeCollect(prevRaw);
        prev.invariantId = keccak256("WRONG");

        bytes[] memory window = new bytes[](2);
        window[0] = currRaw;
        window[1] = abi.encode(prev);

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_response_RejectsWrongCaller() public {
        BeanstalkTypes.Incident memory incident = _validIncident();

        vm.prank(address(0xCAFE));
        vm.expectRevert(BeanstalkVaultV2.NotDrosera.selector);
        vault.executeResponse(abi.encode(incident));
    }

    function test_response_RejectsWrongTarget() public {
        BeanstalkTypes.Incident memory incident = _validIncident();
        incident.target = address(0xABCD);

        vm.expectRevert(BeanstalkVaultV2.WrongTarget.selector);
        vault.executeResponse(abi.encode(incident));
    }

    function test_response_RejectsWrongInvariant() public {
        BeanstalkTypes.Incident memory incident = _validIncident();
        incident.invariantId = keccak256("BAD_INVARIANT");

        vm.expectRevert(BeanstalkVaultV2.WrongInvariant.selector);
        vault.executeResponse(abi.encode(incident));
    }

    function test_response_RejectsInvalidReason() public {
        BeanstalkTypes.Incident memory incident = _validIncident();
        incident.reason = 99;

        vm.expectRevert(BeanstalkVaultV2.InvalidReason.selector);
        vault.executeResponse(abi.encode(incident));
    }

    function test_response_RejectsExpiredDelayWindow() public {
        BeanstalkTypes.Incident memory incident = _validIncident();
        incident.readyBlock = incident.currentBlock;

        vm.expectRevert(BeanstalkVaultV2.InvalidDelayWindow.selector);
        vault.executeResponse(abi.encode(incident));
    }

    function test_response_IsIdempotentForDuplicateIncident() public {
        BeanstalkTypes.Incident memory incident = _validIncident();
        bytes memory raw = abi.encode(incident);

        vault.executeResponse(raw);
        assertEq(vault.responseCount(), 1);

        vault.executeResponse(raw);
        assertEq(vault.responseCount(), 1);
    }

    function test_response_CooldownActive() public {
        BeanstalkTypes.Incident memory incident1 = _validIncident();
        vault.executeResponse(abi.encode(incident1));

        BeanstalkTypes.Incident memory incident2 = _validIncident();
        incident2.suspect = address(0xDEAD);

        vm.expectRevert(BeanstalkVaultV2.CooldownActive.selector);
        vault.executeResponse(abi.encode(incident2));
    }

    function test_response_VerifiesTargetPausedAfterPauseCall() public {
        NoPauseTarget badTarget = new NoPauseTarget();
        BeanstalkVaultV2 badVault = new BeanstalkVaultV2(
            address(badTarget),
            address(this),
            33
        );

        BeanstalkTypes.Incident memory incident = _validIncident();
        incident.target = address(badTarget);

        vm.expectRevert(BeanstalkVaultV2.PauseFailed.selector);
        badVault.executeResponse(abi.encode(incident));
    }

    function test_withoutResponse_DelayedExploitDrains() public {
        uint256 treasuryBefore = protocol.treasury();

        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        vm.roll(block.number + 1);
        attacker.drainTreasury();

        assertEq(protocol.treasury(), 0);
        assertGt(treasuryBefore, 0);
    }

    function test_withResponse_DelayedExploitBlocked() public {
        uint256 treasuryBefore = protocol.treasury();

        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        attacker.acquireFlashVotes();
        attacker.queueEmergencyCommit();
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, bytes memory response) = trap.shouldRespond(window);
        assertTrue(trigger);

        vault.executeResponse(response);
        assertTrue(protocol.paused());

        vm.roll(block.number + 1);
        vm.expectRevert(bytes("BeanstalkMock: protocol is paused"));
        attacker.drainTreasury();

        assertEq(protocol.treasury(), treasuryBefore);
    }

    function test_atomicSameTxExploit_RevertsFromProtocolDelay() public {
        vm.expectRevert(bytes("BeanstalkMock: execution delay active"));
        attacker.atomicAttack();
    }

    function test_slowSafeGovernancePath_BelowSupermajority_DoesNotTrigger()
        public
    {
        address alice = address(0xA11CE);

        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        protocol.acquireVotesSlowly(alice, 100 ether);
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }
}
