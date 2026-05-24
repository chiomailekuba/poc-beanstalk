// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BeanstalkAttacker.sol";
import "../src/BeanstalkMock.sol";
import "../src/BeanstalkTrapV3.sol";
import "../src/BeanstalkTypes.sol";
import "../src/BeanstalkVaultV3.sol";

contract TrapHarnessV3 is BeanstalkTrapV3 {
    address private immutable configuredTarget;

    constructor(address targetAddress) {
        configuredTarget = targetAddress;
    }

    function _target() internal view override returns (address) {
        return configuredTarget;
    }
}

contract MalformedSnapshotReturnMock {
    function getTrapSnapshot()
        external
        pure
        returns (uint256, uint256, address, uint256, uint256, bool)
    {
        assembly {
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }
}

contract NoPauseTargetV3 {
    bool public paused;

    function pause() external {
        // Intentionally no-op so vault pause verification fails.
    }
}

contract BeanstalkMitigationV3Test is Test {
    address private constant PLACEHOLDER =
        address(0x000000000000000000000000000000000000bEEF);

    BeanstalkMock internal protocol;
    BeanstalkAttacker internal attacker;
    TrapHarnessV3 internal trap;
    BeanstalkVaultV3 internal vault;

    function setUp() public {
        protocol = new BeanstalkMock();
        attacker = new BeanstalkAttacker(address(protocol));
        trap = new TrapHarnessV3(address(protocol));
        vault = new BeanstalkVaultV3(address(protocol), address(this), 33);
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

    function test_ShouldRespond_RejectsWrongSampleCount() public {
        bytes[] memory one = new bytes[](1);
        one[0] = trap.collect();
        (bool t1, ) = trap.shouldRespond(one);
        assertFalse(t1);

        bytes[] memory three = new bytes[](3);
        three[0] = trap.collect();
        three[1] = trap.collect();
        three[2] = trap.collect();
        (bool t2, ) = trap.shouldRespond(three);
        assertFalse(t2);
    }

    function test_ShouldRespond_MalformedSameLengthSampleDoesNotRevert()
        public
    {
        bytes[] memory window = new bytes[](2);
        window[0] = new bytes(10 * 32);
        window[1] = trap.collect();

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_ShouldAlert_ReturnsTypedAlertForMalformedSample() public {
        bytes[] memory window = new bytes[](1);
        window[0] = new bytes(1);

        (bool alerting, bytes memory raw) = trap.shouldAlert(window);
        assertTrue(alerting);

        BeanstalkTypes.Alert memory alert = trap.decodeAlertOutput(raw);
        assertEq(alert.invariantId, BeanstalkTypes.INVARIANT_ID);
        assertEq(alert.status, BeanstalkTypes.STATUS_INVALID_SAMPLE);
        assertEq(alert.reason, BeanstalkTypes.REASON_INVALID_SAMPLE_WINDOW);
    }

    function test_Collect_MalformedSnapshotReturnDoesNotRevert() public {
        MalformedSnapshotReturnMock bad = new MalformedSnapshotReturnMock();
        TrapHarnessV3 badTrap = new TrapHarnessV3(address(bad));

        BeanstalkTypes.CollectOutput memory out = _decodeCollect(
            badTrap.collect()
        );

        assertEq(out.status, BeanstalkTypes.STATUS_READ_FAILED);
    }

    function test_Response_DuplicateIncidentIsIdempotentNoOp() public {
        BeanstalkTypes.Incident memory incident = _validIncident();
        bytes memory raw = abi.encode(incident);

        vault.executeResponse(raw);
        assertEq(vault.responseCount(), 1);

        vault.executeResponse(raw);
        assertEq(vault.responseCount(), 1);
    }

    function test_Response_RejectsWrongPayloadLength() public {
        vm.expectRevert(BeanstalkVaultV3.InvalidPayload.selector);
        vault.executeResponse(new bytes(1));
    }

    function test_Response_VerifiesPauseTookEffect() public {
        NoPauseTargetV3 noPause = new NoPauseTargetV3();
        BeanstalkVaultV3 badVault = new BeanstalkVaultV3(
            address(noPause),
            address(this),
            33
        );

        BeanstalkTypes.Incident memory incident = _validIncident();
        incident.target = address(noPause);

        vm.expectRevert(BeanstalkVaultV3.PauseFailed.selector);
        badVault.executeResponse(abi.encode(incident));
    }

    function test_Response_RejectsInvalidReason() public {
        BeanstalkTypes.Incident memory incident = _validIncident();
        incident.reason = 999;

        vm.expectRevert(BeanstalkVaultV3.InvalidReason.selector);
        vault.executeResponse(abi.encode(incident));
    }

    function test_Response_RejectsWrongTarget() public {
        BeanstalkTypes.Incident memory incident = _validIncident();
        incident.target = address(0xBADA55);

        vm.expectRevert(BeanstalkVaultV3.WrongTarget.selector);
        vault.executeResponse(abi.encode(incident));
    }

    function test_TrapUsesRealGeneratedTarget_NotPlaceholder() public {
        BeanstalkTypes.CollectOutput memory out = _decodeCollect(
            trap.collect()
        );

        assertEq(out.target, address(protocol));
        assertTrue(out.target != PLACEHOLDER);
    }
}
