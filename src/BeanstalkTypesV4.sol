// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library BeanstalkTypesV4 {
    bytes32 internal constant INVARIANT_ID =
        keccak256("BEANSTALK_PROPOSAL_THRESHOLD_DELAY_WINDOW_V4");

    uint256 internal constant STATUS_OK = 0;
    uint256 internal constant STATUS_TARGET_MISSING = 1;
    uint256 internal constant STATUS_READ_FAILED = 2;
    uint256 internal constant STATUS_INVALID_SAMPLE = 3;

    uint256 internal constant REASON_THRESHOLD_CROSS_DELAY_WINDOW = 1;
    uint256 internal constant REASON_COORDINATED_MULTI_SUPPORTER = 2;
    uint256 internal constant REASON_SINGLE_WHALE_SUPPORT = 3;
    uint256 internal constant REASON_OPERATIONAL_FAILURE = 4;
    uint256 internal constant REASON_INVALID_SAMPLE_WINDOW = 5;
    uint256 internal constant REASON_TARGET_MISSING = 6;
    uint256 internal constant REASON_READ_FAILED = 7;

    uint256 internal constant SEVERITY_WARNING = 1;
    uint256 internal constant SEVERITY_CRITICAL = 3;

    struct CollectOutput {
        uint256 schemaVersion;
        uint256 status;
        bytes32 invariantId;
        address target;
        uint256 proposalId;
        address proposer;
        address proposalTarget;
        bytes32 proposalCalldataHash;
        uint256 proposalForVotes;
        uint256 proposalThresholdVotes;
        uint256 supportVoterCount;
        uint256 topSupporterVotes;
        uint256 queued;
        uint256 readyBlock;
        uint256 blockNumber;
        uint256 paused;
        uint256 executed;
        uint256 canceled;
    }

    struct Incident {
        bytes32 invariantId;
        address target;
        uint256 proposalId;
        address proposer;
        address proposalTarget;
        bytes32 proposalCalldataHash;
        uint256 currentForVotes;
        uint256 previousForVotes;
        uint256 thresholdVotes;
        uint256 supportVoterCount;
        uint256 topSupporterVotes;
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
