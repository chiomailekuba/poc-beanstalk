// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BeanstalkGovernanceMockV4.sol";
import "../src/BeanstalkTrapV4.sol";
import "../src/BeanstalkTypesV4.sol";
import "../src/BeanstalkVaultV4.sol";

contract TrapHarnessV4 is BeanstalkTrapV4 {
    address private immutable configuredTarget;

    constructor(address targetAddress) {
        configuredTarget = targetAddress;
    }

    function _target() internal view override returns (address) {
        return configuredTarget;
    }
}

contract TrapHarnessV4NoCodeTarget is BeanstalkTrapV4 {
    function _target() internal pure override returns (address) {
        return address(0x000000000000000000000000000000000000bEEF);
    }
}

contract NoCancelTargetV4 {
    bool public paused;

    function pause() external {
        paused = true;
    }
    function cancelProposal(uint256) external {
        /* intentional no-op */
    }
    function proposalCanceled(uint256) external pure returns (bool) {
        return false;
    }

    function getTrapSnapshot()
        external
        pure
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            address,
            address,
            bytes32
        )
    {
        return (
            1000,
            1000,
            1,
            1000,
            1,
            2,
            1,
            0,
            0,
            0,
            1,
            address(0),
            address(0),
            bytes32(0)
        );
    }
}

contract BeanstalkMitigationV4Test is Test {
    BeanstalkGovernanceMockV4 internal protocol;
    TrapHarnessV4 internal trap;
    BeanstalkVaultV4 internal vault;

    address internal voterA = address(0xA11CE);
    address internal voterB = address(0xB0B);

    function _decodeAlert(
        bytes memory raw
    ) internal pure returns (BeanstalkTypesV4.Alert memory) {
        return abi.decode(raw, (BeanstalkTypesV4.Alert));
    }

    function setUp() public {
        protocol = new BeanstalkGovernanceMockV4();
        trap = new TrapHarnessV4(address(protocol));
        vault = new BeanstalkVaultV4(address(protocol), address(this), 33);
        protocol.setPauseGuardian(address(vault));
        protocol.createEmergencyProposal(address(protocol), "", 1000);
    }

    function _vote(address who, uint256 amount) internal {
        vm.prank(who);
        protocol.supportProposal(amount);
    }

    function test_withoutResponse_DelayedExploitDrains() public {
        _vote(voterA, 400);
        _vote(voterB, 700);

        protocol.queueProposal();
        vm.roll(block.number + 1);
        protocol.executeProposal();

        assertEq(protocol.treasury(), 0);
    }

    function test_withResponse_DelayedExploitBlocked() public {
        _vote(voterA, 400);
        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterB, 700);
        protocol.queueProposal();

        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, bytes memory response) = trap.shouldRespond(window);
        assertTrue(
            trigger,
            "V4 trap should fire on proposal threshold cross in timelock"
        );

        vault.executeResponse(response);
        assertTrue(protocol.paused(), "Protocol should be paused by response");
        assertTrue(
            protocol.canceled(),
            "Proposal should be canceled by response"
        );

        vm.roll(block.number + 1);
        vm.expectRevert(bytes("BeanstalkGovernanceMockV4: protocol is paused"));
        protocol.executeProposal();

        assertEq(protocol.treasury(), protocol.INITIAL_TREASURY());
    }

    function test_reason_CoordinatedAttack_WhenMultipleSupporters() public {
        _vote(voterA, 400);
        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterB, 700);
        protocol.queueProposal();
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, bytes memory response) = trap.shouldRespond(window);
        assertTrue(trigger);

        BeanstalkTypesV4.Incident memory incident = abi.decode(
            response,
            (BeanstalkTypesV4.Incident)
        );

        assertEq(
            incident.reason,
            BeanstalkTypesV4.REASON_COORDINATED_MULTI_SUPPORTER
        );
    }

    function test_reason_SingleWhale_WhenTopSupporterCrossesThreshold() public {
        _vote(voterA, 200);
        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterA, 900);
        protocol.queueProposal();
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, bytes memory response) = trap.shouldRespond(window);
        assertTrue(trigger);

        BeanstalkTypesV4.Incident memory incident = abi.decode(
            response,
            (BeanstalkTypesV4.Incident)
        );

        assertEq(incident.reason, BeanstalkTypesV4.REASON_SINGLE_WHALE_SUPPORT);
    }

    function test_noTrigger_WhenAlreadyExecuted() public {
        _vote(voterA, 1000);
        protocol.queueProposal();
        vm.roll(block.number + 1);
        protocol.executeProposal();

        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_noTrigger_WhenCanceled() public {
        _vote(voterA, 400);
        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterB, 700);
        protocol.queueProposal();
        protocol.cancelProposal(1);
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_response_CooldownActiveForNewIncident() public {
        _vote(voterA, 400);
        bytes memory prev1 = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterB, 700);
        protocol.queueProposal();
        bytes memory curr1 = trap.collect();

        bytes[] memory window1 = new bytes[](2);
        window1[0] = curr1;
        window1[1] = prev1;

        (bool trigger1, bytes memory response1) = trap.shouldRespond(window1);
        assertTrue(trigger1);
        vault.executeResponse(response1);

        // Build a second distinct valid incident and ensure cooldown blocks it.
        BeanstalkTypesV4.Incident memory incident1 = abi.decode(
            response1,
            (BeanstalkTypesV4.Incident)
        );

        BeanstalkTypesV4.Incident memory incident2 = incident1;
        incident2.currentForVotes = incident1.currentForVotes + 500;
        incident2.previousForVotes = incident1.previousForVotes + 100;
        incident2.currentBlock = incident1.currentBlock + 1;
        incident2.previousBlock = incident1.previousBlock + 1;
        incident2.readyBlock = incident2.currentBlock + 1;

        bytes memory response2 = abi.encode(incident2);

        vm.expectRevert(BeanstalkVaultV4.CooldownActive.selector);
        vault.executeResponse(response2);
    }

    function test_createProposal_ResetsVoterStateAcrossProposalNonce() public {
        _vote(voterA, 1200);
        protocol.queueProposal();
        vm.roll(block.number + 1);
        protocol.executeProposal();

        vm.roll(block.number + 1);
        protocol.createEmergencyProposal(address(protocol), "", 900);

        // Same voter should count once for the new proposal despite old state.
        _vote(voterA, 900);

        assertEq(protocol.supportVoterCount(), 1);
        assertEq(protocol.topSupporterVotes(), 900);
        assertEq(protocol.proposalForVotes(), 900);
    }

    function test_shouldAlert_TrueForWrongSampleCount() public {
        bytes[] memory one = new bytes[](1);
        one[0] = trap.collect();

        (bool alerting, bytes memory raw) = trap.shouldAlert(one);
        assertTrue(alerting);

        BeanstalkTypesV4.Alert memory alert = _decodeAlert(raw);
        assertEq(alert.reason, BeanstalkTypesV4.REASON_INVALID_SAMPLE_WINDOW);
        assertEq(alert.status, BeanstalkTypesV4.STATUS_INVALID_SAMPLE);
    }

    function test_shouldAlert_TrueForTargetMissing() public {
        TrapHarnessV4NoCodeTarget badTrap = new TrapHarnessV4NoCodeTarget();

        bytes[] memory window = new bytes[](2);
        window[0] = badTrap.collect();
        window[1] = badTrap.collect();

        (bool alerting, bytes memory raw) = badTrap.shouldAlert(window);
        assertTrue(alerting);

        BeanstalkTypesV4.Alert memory alert = _decodeAlert(raw);
        assertEq(alert.reason, BeanstalkTypesV4.REASON_TARGET_MISSING);
        assertEq(alert.status, BeanstalkTypesV4.STATUS_TARGET_MISSING);
        assertEq(alert.severity, BeanstalkTypesV4.SEVERITY_CRITICAL);
    }

    function test_Response_CancelFailedReverts() public {
        NoCancelTargetV4 noCancel = new NoCancelTargetV4();
        BeanstalkVaultV4 badVault = new BeanstalkVaultV4(
            address(noCancel),
            address(this),
            33
        );

        BeanstalkTypesV4.Incident memory incident = BeanstalkTypesV4.Incident({
            invariantId: BeanstalkTypesV4.INVARIANT_ID,
            target: address(noCancel),
            proposalId: 1,
            proposer: address(this),
            proposalTarget: address(noCancel),
            proposalCalldataHash: bytes32(0),
            currentForVotes: 1000,
            previousForVotes: 0,
            thresholdVotes: 1000,
            supportVoterCount: 1,
            topSupporterVotes: 1000,
            currentBlock: block.number,
            previousBlock: block.number - 1,
            readyBlock: block.number + 1,
            reason: BeanstalkTypesV4.REASON_SINGLE_WHALE_SUPPORT
        });

        vm.expectRevert(BeanstalkVaultV4.CancelFailed.selector);
        badVault.executeResponse(abi.encode(incident));
    }
}
