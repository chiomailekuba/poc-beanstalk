// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library BeanstalkTypes {
    bytes32 internal constant INVARIANT_ID =
        keccak256("BEANSTALK_GOVERNANCE_DELAY_SUPERMAJORITY_V1");

    uint8 internal constant STATUS_OK = 0;
    uint8 internal constant STATUS_TARGET_MISSING = 1;
    uint8 internal constant STATUS_READ_FAILED = 2;
    uint8 internal constant STATUS_ZERO_TOTAL_STALK = 3;
    uint8 internal constant STATUS_ALREADY_PAUSED = 4;

    uint8 internal constant REASON_SUPERMAJORITY_DELAY_WINDOW = 1;
    uint8 internal constant REASON_TOP_HOLDER_FLIP = 2;
    uint8 internal constant REASON_OPERATIONAL_FAILURE = 3;

    struct CollectOutput {
        uint8 schemaVersion;
        uint8 status;
        bytes32 invariantId;
        address target;
        uint256 totalStalk;
        uint256 topHolderStalk;
        address topHolder;
        uint256 topHolderReadyBlock;
        uint256 blockNumber;
        bool paused;
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
        uint8 reason;
    }
}
