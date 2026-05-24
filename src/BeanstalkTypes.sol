// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library BeanstalkTypes {
    bytes32 internal constant INVARIANT_ID =
        keccak256("BEANSTALK_GOVERNANCE_DELAY_SUPERMAJORITY_V2");

    uint256 internal constant STATUS_OK = 0;
    uint256 internal constant STATUS_TARGET_MISSING = 1;
    uint256 internal constant STATUS_READ_FAILED = 2;
    uint256 internal constant STATUS_ZERO_TOTAL_STALK = 3;
    uint256 internal constant STATUS_ALREADY_PAUSED = 4;
    uint256 internal constant STATUS_INVALID_SAMPLE = 5;

    uint256 internal constant REASON_SUPERMAJORITY_DELAY_WINDOW = 1;
    uint256 internal constant REASON_TOP_HOLDER_FLIP = 2;
    uint256 internal constant REASON_OPERATIONAL_FAILURE = 3;
    uint256 internal constant REASON_INVALID_SAMPLE_WINDOW = 4;
    uint256 internal constant REASON_TARGET_MISSING = 5;
    uint256 internal constant REASON_READ_FAILED = 6;
    uint256 internal constant REASON_ZERO_TOTAL_STALK = 7;
    uint256 internal constant REASON_ALREADY_PAUSED = 8;

    uint256 internal constant SEVERITY_WARNING = 1;
    uint256 internal constant SEVERITY_CRITICAL = 3;

    // Keep every field ABI-word-sized for deterministic raw parsing.
    struct CollectOutput {
        uint256 schemaVersion;
        uint256 status;
        bytes32 invariantId;
        address target;
        uint256 totalStalk;
        uint256 topHolderStalk;
        address topHolder;
        uint256 topHolderReadyBlock;
        uint256 blockNumber;
        uint256 paused; // 0=false, nonzero=true
    }

    struct Incident {
        bytes32 invariantId;
        address target;
        address suspect;
        uint256 currentTopStake;
        uint256 previousTopStake;
        uint256 currentTotalStalk;
        uint256 previousTotalStalk;
        uint256 currentBlock;
        uint256 previousBlock;
        uint256 readyBlock;
        uint256 reason;
    }

    struct Alert {
        bytes32 invariantId;
        address target;
        uint256 blockNumber;
        uint256 status;
        uint256 reason;
        uint256 severity;
        bytes extraData;
    }
}
