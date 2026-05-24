// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ITrap.sol";
import "./TrapDeployConfig.sol";
import "./BeanstalkTypes.sol";

contract BeanstalkTrapV3 is ITrap {
    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant REQUIRED_SAMPLES = 2;
    uint256 public constant SUPERMAJORITY_NUMERATOR = 67;
    uint256 public constant SUPERMAJORITY_DENOMINATOR = 100;

    // 10 fields * 32 bytes.
    uint256 public constant COLLECT_OUTPUT_SIZE = 10 * 32;

    // getTrapSnapshot() returns 6 ABI words.
    uint256 public constant SNAPSHOT_RETURN_SIZE = 6 * 32;

    function _target() internal view virtual returns (address) {
        return TrapDeployConfig.TARGET;
    }

    function collect() external view override returns (bytes memory) {
        address target = _target();

        BeanstalkTypes.CollectOutput memory out;
        out.schemaVersion = SCHEMA_VERSION;
        out.status = BeanstalkTypes.STATUS_OK;
        out.invariantId = BeanstalkTypes.INVARIANT_ID;
        out.target = target;
        out.blockNumber = block.number;

        if (target == address(0) || target.code.length == 0) {
            out.status = BeanstalkTypes.STATUS_TARGET_MISSING;
            return abi.encode(out);
        }

        (bool ok, bytes memory raw) = target.staticcall(
            abi.encodeWithSignature("getTrapSnapshot()")
        );

        if (!ok || raw.length != SNAPSHOT_RETURN_SIZE) {
            out.status = BeanstalkTypes.STATUS_READ_FAILED;
            return abi.encode(out);
        }

        (
            uint256 total,
            uint256 topStalk,
            address topHolder,
            uint256 topReadyBlock,
            uint256 snapshotBlock,
            uint256 pausedWord
        ) = _decodeSnapshotReturn(raw);

        out.totalStalk = total;
        out.topHolderStalk = topStalk;
        out.topHolder = topHolder;
        out.topHolderReadyBlock = topReadyBlock;
        out.blockNumber = snapshotBlock;
        out.paused = pausedWord == 0 ? 0 : 1;

        if (out.paused != 0) {
            out.status = BeanstalkTypes.STATUS_ALREADY_PAUSED;
            return abi.encode(out);
        }

        if (total == 0) {
            out.status = BeanstalkTypes.STATUS_ZERO_TOTAL_STALK;
            return abi.encode(out);
        }

        return abi.encode(out);
    }

    function shouldRespond(
        bytes[] calldata data
    ) external pure override returns (bool, bytes memory) {
        if (data.length != REQUIRED_SAMPLES) return (false, bytes(""));

        (
            bool currentOk,
            BeanstalkTypes.CollectOutput memory current
        ) = _decodeCollectOutput(data[0]);
        (
            bool previousOk,
            BeanstalkTypes.CollectOutput memory previous
        ) = _decodeCollectOutput(data[1]);

        if (!currentOk || !previousOk) return (false, bytes(""));
        if (!_validPair(current, previous)) return (false, bytes(""));

        if (current.status != BeanstalkTypes.STATUS_OK)
            return (false, bytes(""));
        if (previous.status != BeanstalkTypes.STATUS_OK)
            return (false, bytes(""));
        if (current.paused != 0) return (false, bytes(""));

        bool hasSuperMajority = current.topHolderStalk *
            SUPERMAJORITY_DENOMINATOR >=
            current.totalStalk * SUPERMAJORITY_NUMERATOR;

        bool stakeIncreased = current.topHolderStalk > previous.topHolderStalk;
        bool insideDelayWindow = current.topHolderReadyBlock >
            current.blockNumber;

        if (!hasSuperMajority || !stakeIncreased || !insideDelayWindow) {
            return (false, bytes(""));
        }

        uint256 reason = BeanstalkTypes.REASON_SUPERMAJORITY_DELAY_WINDOW;
        if (
            previous.topHolder != address(0) &&
            previous.topHolder != current.topHolder
        ) {
            reason = BeanstalkTypes.REASON_TOP_HOLDER_FLIP;
        }

        BeanstalkTypes.Incident memory incident = BeanstalkTypes.Incident({
            invariantId: BeanstalkTypes.INVARIANT_ID,
            target: current.target,
            suspect: current.topHolder,
            currentTopStake: current.topHolderStalk,
            previousTopStake: previous.topHolderStalk,
            currentTotalStalk: current.totalStalk,
            previousTotalStalk: previous.totalStalk,
            currentBlock: current.blockNumber,
            previousBlock: previous.blockNumber,
            readyBlock: current.topHolderReadyBlock,
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
                    BeanstalkTypes.STATUS_INVALID_SAMPLE,
                    BeanstalkTypes.REASON_INVALID_SAMPLE_WINDOW,
                    abi.encode(data.length)
                );
        }

        (
            bool currentOk,
            BeanstalkTypes.CollectOutput memory current
        ) = _decodeCollectOutput(data[0]);
        if (!currentOk) {
            return
                _alert(
                    address(0),
                    0,
                    BeanstalkTypes.STATUS_INVALID_SAMPLE,
                    BeanstalkTypes.REASON_OPERATIONAL_FAILURE,
                    bytes("")
                );
        }

        uint256 reason;

        if (current.status == BeanstalkTypes.STATUS_TARGET_MISSING) {
            reason = BeanstalkTypes.REASON_TARGET_MISSING;
        } else if (current.status == BeanstalkTypes.STATUS_READ_FAILED) {
            reason = BeanstalkTypes.REASON_READ_FAILED;
        } else if (current.status == BeanstalkTypes.STATUS_ZERO_TOTAL_STALK) {
            reason = BeanstalkTypes.REASON_ZERO_TOTAL_STALK;
        } else if (current.status == BeanstalkTypes.STATUS_ALREADY_PAUSED) {
            reason = BeanstalkTypes.REASON_ALREADY_PAUSED;
        } else {
            (
                bool previousOk,
                BeanstalkTypes.CollectOutput memory previous
            ) = _decodeCollectOutput(data[1]);
            if (!previousOk || !_validPair(current, previous)) {
                reason = BeanstalkTypes.REASON_INVALID_SAMPLE_WINDOW;
            }
        }

        if (reason == 0) return (false, bytes(""));

        return
            _alert(
                current.target,
                current.blockNumber,
                current.status,
                reason,
                bytes("")
            );
    }

    function decodeAlertOutput(
        bytes calldata raw
    ) external pure returns (BeanstalkTypes.Alert memory) {
        return abi.decode(raw, (BeanstalkTypes.Alert));
    }

    function _validPair(
        BeanstalkTypes.CollectOutput memory current,
        BeanstalkTypes.CollectOutput memory previous
    ) internal pure returns (bool) {
        if (current.schemaVersion != SCHEMA_VERSION) return false;
        if (previous.schemaVersion != SCHEMA_VERSION) return false;

        if (current.invariantId != BeanstalkTypes.INVARIANT_ID) return false;
        if (previous.invariantId != BeanstalkTypes.INVARIANT_ID) return false;

        if (current.target == address(0) || previous.target == address(0))
            return false;
        if (current.target != previous.target) return false;

        if (current.blockNumber != previous.blockNumber + 1) return false;

        return true;
    }

    function _alert(
        address target,
        uint256 blockNumber,
        uint256 status,
        uint256 reason,
        bytes memory extraData
    ) internal pure returns (bool, bytes memory) {
        BeanstalkTypes.Alert memory alert = BeanstalkTypes.Alert({
            invariantId: BeanstalkTypes.INVARIANT_ID,
            target: target,
            blockNumber: blockNumber,
            status: status,
            reason: reason,
            severity: BeanstalkTypes.SEVERITY_WARNING,
            extraData: extraData
        });

        return (true, abi.encode(alert));
    }

    function _decodeCollectOutput(
        bytes calldata raw
    ) internal pure returns (bool, BeanstalkTypes.CollectOutput memory out) {
        if (raw.length != COLLECT_OUTPUT_SIZE) return (false, out);

        out.schemaVersion = _uintAt(raw, 0);
        out.status = _uintAt(raw, 1);
        out.invariantId = _wordAt(raw, 2);
        out.target = _addressAt(raw, 3);
        out.totalStalk = _uintAt(raw, 4);
        out.topHolderStalk = _uintAt(raw, 5);
        out.topHolder = _addressAt(raw, 6);
        out.topHolderReadyBlock = _uintAt(raw, 7);
        out.blockNumber = _uintAt(raw, 8);
        out.paused = _uintAt(raw, 9) == 0 ? 0 : 1;

        return (true, out);
    }

    function _decodeSnapshotReturn(
        bytes memory raw
    )
        internal
        pure
        returns (
            uint256 total,
            uint256 topStalk,
            address topHolder,
            uint256 topReadyBlock,
            uint256 snapshotBlock,
            uint256 pausedWord
        )
    {
        total = _memUintAt(raw, 0);
        topStalk = _memUintAt(raw, 1);
        topHolder = address(uint160(_memUintAt(raw, 2)));
        topReadyBlock = _memUintAt(raw, 3);
        snapshotBlock = _memUintAt(raw, 4);
        pausedWord = _memUintAt(raw, 5);
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
