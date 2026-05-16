// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ITrap.sol";
import "./TrapDeployConfig.sol";
import "./BeanstalkTypes.sol";

interface IBeanstalkTrapSnapshotTarget {
    function getTrapSnapshot()
        external
        view
        returns (
            uint256 snapshotTotalStalk,
            uint256 snapshotTopHolderStalk,
            address snapshotTopHolder,
            uint256 snapshotTopHolderReadyBlock,
            uint256 snapshotBlock,
            bool snapshotPaused
        );
}

contract BeanstalkTrapV2 is ITrap {
    uint8 public constant SCHEMA_VERSION = 1;
    uint256 public constant SUPERMAJORITY_NUMERATOR = 67;
    uint256 public constant SUPERMAJORITY_DENOMINATOR = 100;
    uint256 public constant COLLECT_OUTPUT_SIZE = 320;

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

        if (target.code.length == 0) {
            out.status = BeanstalkTypes.STATUS_TARGET_MISSING;
            return abi.encode(out);
        }

        (bool ok, bytes memory raw) = target.staticcall(
            abi.encodeWithSignature("getTrapSnapshot()")
        );

        if (!ok || raw.length != 192) {
            out.status = BeanstalkTypes.STATUS_READ_FAILED;
            return abi.encode(out);
        }

        (
            uint256 total,
            uint256 topStalk,
            address topHolder,
            uint256 topReadyBlock,
            uint256 blockNumber,
            bool paused
        ) = abi.decode(
                raw,
                (uint256, uint256, address, uint256, uint256, bool)
            );

        out.totalStalk = total;
        out.topHolderStalk = topStalk;
        out.topHolder = topHolder;
        out.topHolderReadyBlock = topReadyBlock;
        out.blockNumber = blockNumber;
        out.paused = paused;

        if (paused) {
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
    ) external pure override returns (bool trigger, bytes memory response) {
        if (data.length < 2) return (false, bytes(""));
        if (data[0].length != COLLECT_OUTPUT_SIZE) return (false, bytes(""));
        if (data[1].length != COLLECT_OUTPUT_SIZE) return (false, bytes(""));

        BeanstalkTypes.CollectOutput memory current = abi.decode(
            data[0],
            (BeanstalkTypes.CollectOutput)
        );

        BeanstalkTypes.CollectOutput memory previous = abi.decode(
            data[1],
            (BeanstalkTypes.CollectOutput)
        );

        if (current.schemaVersion != SCHEMA_VERSION) return (false, bytes(""));
        if (previous.schemaVersion != SCHEMA_VERSION) return (false, bytes(""));

        if (current.status != BeanstalkTypes.STATUS_OK)
            return (false, bytes(""));
        if (previous.status != BeanstalkTypes.STATUS_OK)
            return (false, bytes(""));

        if (current.invariantId != BeanstalkTypes.INVARIANT_ID)
            return (false, bytes(""));
        if (previous.invariantId != BeanstalkTypes.INVARIANT_ID)
            return (false, bytes(""));

        if (current.target == address(0) || previous.target == address(0)) {
            return (false, bytes(""));
        }

        if (current.target != previous.target) return (false, bytes(""));

        if (current.blockNumber != previous.blockNumber + 1) {
            return (false, bytes(""));
        }

        if (current.paused) return (false, bytes(""));

        bool hasSuperMajority = current.topHolderStalk *
            SUPERMAJORITY_DENOMINATOR >=
            current.totalStalk * SUPERMAJORITY_NUMERATOR;

        bool stakeIncreased = current.topHolderStalk > previous.topHolderStalk;
        bool insideDelayWindow = current.topHolderReadyBlock >
            current.blockNumber;

        if (!hasSuperMajority || !stakeIncreased || !insideDelayWindow) {
            return (false, bytes(""));
        }

        uint8 reason = BeanstalkTypes.REASON_SUPERMAJORITY_DELAY_WINDOW;
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
        if (data.length == 0 || data[0].length != COLLECT_OUTPUT_SIZE) {
            return (true, abi.encode(uint8(BeanstalkTypes.REASON_OPERATIONAL_FAILURE)));
        }

        BeanstalkTypes.CollectOutput memory current = abi.decode(
            data[0],
            (BeanstalkTypes.CollectOutput)
        );

        if (
            current.status == BeanstalkTypes.STATUS_TARGET_MISSING ||
            current.status == BeanstalkTypes.STATUS_READ_FAILED ||
            current.status == BeanstalkTypes.STATUS_ZERO_TOTAL_STALK
        ) {
            return (true, abi.encode(current));
        }

        return (false, bytes(""));
    }
}
