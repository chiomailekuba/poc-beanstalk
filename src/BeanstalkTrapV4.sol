// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ITrap.sol";
import "./TrapDeployConfig.sol";
import "./BeanstalkTypesV4.sol";

contract BeanstalkTrapV4 is ITrap {
    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant REQUIRED_SAMPLES = 2;
    uint256 public constant COLLECT_OUTPUT_SIZE = 18 * 32;
    uint256 public constant SNAPSHOT_RETURN_SIZE = 14 * 32;

    function _target() internal view virtual returns (address) {
        return TrapDeployConfig.TARGET;
    }

    function collect() external view override returns (bytes memory) {
        address target = _target();

        BeanstalkTypesV4.CollectOutput memory out;
        out.schemaVersion = SCHEMA_VERSION;
        out.status = BeanstalkTypesV4.STATUS_OK;
        out.invariantId = BeanstalkTypesV4.INVARIANT_ID;
        out.target = target;
        out.blockNumber = block.number;

        if (target == address(0) || target.code.length == 0) {
            out.status = BeanstalkTypesV4.STATUS_TARGET_MISSING;
            return abi.encode(out);
        }

        (bool ok, bytes memory raw) = target.staticcall(
            abi.encodeWithSignature("getTrapSnapshot()")
        );

        if (!ok || raw.length != SNAPSHOT_RETURN_SIZE) {
            out.status = BeanstalkTypesV4.STATUS_READ_FAILED;
            return abi.encode(out);
        }

        out.proposalForVotes = _memUintAt(raw, 0);
        out.proposalThresholdVotes = _memUintAt(raw, 1);
        out.supportVoterCount = _memUintAt(raw, 2);
        out.topSupporterVotes = _memUintAt(raw, 3);
        out.queued = _memUintAt(raw, 4) == 0 ? 0 : 1;
        out.readyBlock = _memUintAt(raw, 5);
        out.blockNumber = _memUintAt(raw, 6);
        out.paused = _memUintAt(raw, 7) == 0 ? 0 : 1;
        out.executed = _memUintAt(raw, 8) == 0 ? 0 : 1;
        out.canceled = _memUintAt(raw, 9) == 0 ? 0 : 1;
        out.proposalId = _memUintAt(raw, 10);
        out.proposer = address(uint160(_memUintAt(raw, 11)));
        out.proposalTarget = address(uint160(_memUintAt(raw, 12)));
        out.proposalCalldataHash = bytes32(_memUintAt(raw, 13));

        return abi.encode(out);
    }

    function shouldRespond(
        bytes[] calldata data
    ) external pure override returns (bool, bytes memory) {
        if (data.length != REQUIRED_SAMPLES) return (false, bytes(""));

        (
            bool currentOk,
            BeanstalkTypesV4.CollectOutput memory current
        ) = _decodeCollectOutput(data[0]);
        (
            bool previousOk,
            BeanstalkTypesV4.CollectOutput memory previous
        ) = _decodeCollectOutput(data[1]);

        if (!currentOk || !previousOk) return (false, bytes(""));
        if (!_validPair(current, previous)) return (false, bytes(""));

        bool crossedThreshold = current.proposalForVotes >=
            current.proposalThresholdVotes &&
            previous.proposalForVotes < previous.proposalThresholdVotes;

        bool insideTimelockWindow = current.readyBlock > current.blockNumber;

        if (
            !crossedThreshold ||
            current.queued == 0 ||
            !insideTimelockWindow ||
            current.paused != 0 ||
            current.executed != 0 ||
            current.canceled != 0
        ) {
            return (false, bytes(""));
        }

        uint256 reason = BeanstalkTypesV4.REASON_THRESHOLD_CROSS_DELAY_WINDOW;
        if (current.topSupporterVotes >= current.proposalThresholdVotes) {
            reason = BeanstalkTypesV4.REASON_SINGLE_WHALE_SUPPORT;
        } else if (current.supportVoterCount > 1) {
            reason = BeanstalkTypesV4.REASON_COORDINATED_MULTI_SUPPORTER;
        }

        BeanstalkTypesV4.Incident memory incident = BeanstalkTypesV4.Incident({
            invariantId: BeanstalkTypesV4.INVARIANT_ID,
            target: current.target,
            proposalId: current.proposalId,
            proposer: current.proposer,
            proposalTarget: current.proposalTarget,
            proposalCalldataHash: current.proposalCalldataHash,
            currentForVotes: current.proposalForVotes,
            previousForVotes: previous.proposalForVotes,
            thresholdVotes: current.proposalThresholdVotes,
            supportVoterCount: current.supportVoterCount,
            topSupporterVotes: current.topSupporterVotes,
            currentBlock: current.blockNumber,
            previousBlock: previous.blockNumber,
            readyBlock: current.readyBlock,
            reason: reason
        });

        return (true, abi.encode(incident));
    }

    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length != REQUIRED_SAMPLES) {
            return
                _alert(
                    address(0),
                    0,
                    BeanstalkTypesV4.STATUS_INVALID_SAMPLE,
                    BeanstalkTypesV4.REASON_INVALID_SAMPLE_WINDOW,
                    BeanstalkTypesV4.SEVERITY_WARNING,
                    abi.encode(data.length)
                );
        }

        (
            bool currentOk,
            BeanstalkTypesV4.CollectOutput memory current
        ) = _decodeCollectOutput(data[0]);

        if (!currentOk) {
            return
                _alert(
                    address(0),
                    0,
                    BeanstalkTypesV4.STATUS_INVALID_SAMPLE,
                    BeanstalkTypesV4.REASON_OPERATIONAL_FAILURE,
                    BeanstalkTypesV4.SEVERITY_CRITICAL,
                    bytes("")
                );
        }

        uint256 reason;
        uint256 severity = BeanstalkTypesV4.SEVERITY_WARNING;

        if (current.status == BeanstalkTypesV4.STATUS_TARGET_MISSING) {
            reason = BeanstalkTypesV4.REASON_TARGET_MISSING;
            severity = BeanstalkTypesV4.SEVERITY_CRITICAL;
        } else if (current.status == BeanstalkTypesV4.STATUS_READ_FAILED) {
            reason = BeanstalkTypesV4.REASON_READ_FAILED;
            severity = BeanstalkTypesV4.SEVERITY_CRITICAL;
        } else {
            (
                bool previousOk,
                BeanstalkTypesV4.CollectOutput memory previous
            ) = _decodeCollectOutput(data[1]);

            if (!previousOk || !_validPair(current, previous)) {
                reason = BeanstalkTypesV4.REASON_INVALID_SAMPLE_WINDOW;
            }
        }

        if (reason == 0) {
            return (false, bytes(""));
        }

        return
            _alert(
                current.target,
                current.blockNumber,
                current.status,
                reason,
                severity,
                bytes("")
            );
    }

    function decodeAlertOutput(
        bytes calldata raw
    ) external pure returns (BeanstalkTypesV4.Alert memory) {
        return abi.decode(raw, (BeanstalkTypesV4.Alert));
    }

    function _validPair(
        BeanstalkTypesV4.CollectOutput memory current,
        BeanstalkTypesV4.CollectOutput memory previous
    ) internal pure returns (bool) {
        if (current.schemaVersion != SCHEMA_VERSION) return false;
        if (previous.schemaVersion != SCHEMA_VERSION) return false;

        if (current.status != BeanstalkTypesV4.STATUS_OK) return false;
        if (previous.status != BeanstalkTypesV4.STATUS_OK) return false;

        if (current.invariantId != BeanstalkTypesV4.INVARIANT_ID) return false;
        if (previous.invariantId != BeanstalkTypesV4.INVARIANT_ID) return false;

        if (current.target == address(0) || previous.target == address(0))
            return false;
        if (current.target != previous.target) return false;

        if (current.proposalId == 0) return false;
        if (current.proposalId != previous.proposalId) return false;

        if (current.blockNumber != previous.blockNumber + 1) return false;

        if (
            current.proposalThresholdVotes == 0 ||
            previous.proposalThresholdVotes == 0
        ) {
            return false;
        }

        return true;
    }

    function _decodeCollectOutput(
        bytes calldata raw
    ) internal pure returns (bool, BeanstalkTypesV4.CollectOutput memory out) {
        if (raw.length != COLLECT_OUTPUT_SIZE) return (false, out);

        out.schemaVersion = _uintAt(raw, 0);
        out.status = _uintAt(raw, 1);
        out.invariantId = _wordAt(raw, 2);
        out.target = _addressAt(raw, 3);
        out.proposalId = _uintAt(raw, 4);
        out.proposer = _addressAt(raw, 5);
        out.proposalTarget = _addressAt(raw, 6);
        out.proposalCalldataHash = _wordAt(raw, 7);
        out.proposalForVotes = _uintAt(raw, 8);
        out.proposalThresholdVotes = _uintAt(raw, 9);
        out.supportVoterCount = _uintAt(raw, 10);
        out.topSupporterVotes = _uintAt(raw, 11);
        out.queued = _uintAt(raw, 12) == 0 ? 0 : 1;
        out.readyBlock = _uintAt(raw, 13);
        out.blockNumber = _uintAt(raw, 14);
        out.paused = _uintAt(raw, 15) == 0 ? 0 : 1;
        out.executed = _uintAt(raw, 16) == 0 ? 0 : 1;
        out.canceled = _uintAt(raw, 17) == 0 ? 0 : 1;

        return (true, out);
    }

    function _alert(
        address target,
        uint256 blockNumber,
        uint256 status,
        uint256 reason,
        uint256 severity,
        bytes memory extraData
    ) internal pure returns (bool, bytes memory) {
        BeanstalkTypesV4.Alert memory alert = BeanstalkTypesV4.Alert({
            invariantId: BeanstalkTypesV4.INVARIANT_ID,
            target: target,
            blockNumber: blockNumber,
            status: status,
            reason: reason,
            severity: severity,
            extraData: extraData
        });

        return (true, abi.encode(alert));
    }

    function _wordAt(
        bytes calldata raw,
        uint256 index
    ) internal pure returns (bytes32 word) {
        assembly {
            word := calldataload(add(raw.offset, mul(index, 32)))
        }
    }

    function _uintAt(
        bytes calldata raw,
        uint256 index
    ) internal pure returns (uint256) {
        return uint256(_wordAt(raw, index));
    }

    function _addressAt(
        bytes calldata raw,
        uint256 index
    ) internal pure returns (address) {
        return address(uint160(uint256(_wordAt(raw, index))));
    }

    function _memUintAt(
        bytes memory raw,
        uint256 index
    ) internal pure returns (uint256 value) {
        assembly {
            value := mload(add(add(raw, 32), mul(index, 32)))
        }
    }
}
