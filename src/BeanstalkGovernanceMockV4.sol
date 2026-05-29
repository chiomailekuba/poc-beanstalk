// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BeanstalkGovernanceMockV4 {
    address public owner;
    address public pauseGuardian;

    uint256 public treasury;
    uint256 public proposalForVotes;
    uint256 public proposalThresholdVotes;
    uint256 public supportVoterCount;
    uint256 public topSupporterVotes;
    bool public queued;
    uint256 public readyBlock;
    bool public paused;
    bool public executed;
    bool public canceled;
    uint256 public proposalNonce;

    mapping(address => uint256) public supporterVotes;
    mapping(address => uint256) public supporterNonce;

    uint256 public constant INITIAL_TREASURY = 182_000_000 ether;
    uint256 public constant QUEUE_DELAY_BLOCKS = 1;

    constructor() {
        owner = msg.sender;
        pauseGuardian = msg.sender;
        treasury = INITIAL_TREASURY;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "BeanstalkGovernanceMockV4: not owner");
        _;
    }

    modifier onlyPauseGuardian() {
        require(
            msg.sender == pauseGuardian,
            "BeanstalkGovernanceMockV4: not guardian"
        );
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner || msg.sender == pauseGuardian,
            "BeanstalkGovernanceMockV4: not owner or guardian"
        );
        _;
    }

    function setPauseGuardian(address guardian) external onlyOwner {
        require(
            guardian != address(0),
            "BeanstalkGovernanceMockV4: invalid guardian"
        );
        pauseGuardian = guardian;
    }

    function createEmergencyProposal(
        uint256 thresholdVotes_
    ) external onlyOwner {
        require(
            !(queued && !executed && !canceled),
            "BeanstalkGovernanceMockV4: active proposal exists"
        );
        require(
            thresholdVotes_ > 0,
            "BeanstalkGovernanceMockV4: invalid threshold"
        );

        proposalForVotes = 0;
        proposalThresholdVotes = thresholdVotes_;
        supportVoterCount = 0;
        topSupporterVotes = 0;
        queued = false;
        readyBlock = 0;
        executed = false;
        canceled = false;
        proposalNonce += 1;
    }

    function supportProposal(uint256 votes) external {
        require(!paused, "BeanstalkGovernanceMockV4: protocol is paused");
        require(
            !executed && !canceled,
            "BeanstalkGovernanceMockV4: proposal closed"
        );
        require(votes > 0, "BeanstalkGovernanceMockV4: invalid votes");

        // Use proposal nonce to avoid stale voter state across proposals.
        if (supporterNonce[msg.sender] != proposalNonce) {
            supporterNonce[msg.sender] = proposalNonce;
            supporterVotes[msg.sender] = 0;
            supportVoterCount += 1;
        } else if (supporterVotes[msg.sender] == 0) {
            supportVoterCount += 1;
        }

        supporterVotes[msg.sender] += votes;
        proposalForVotes += votes;

        if (supporterVotes[msg.sender] > topSupporterVotes) {
            topSupporterVotes = supporterVotes[msg.sender];
        }
    }

    function queueProposal() external {
        require(!paused, "BeanstalkGovernanceMockV4: protocol is paused");
        require(
            !executed && !canceled,
            "BeanstalkGovernanceMockV4: proposal closed"
        );
        require(!queued, "BeanstalkGovernanceMockV4: already queued");
        require(
            proposalForVotes >= proposalThresholdVotes,
            "BeanstalkGovernanceMockV4: threshold not met"
        );

        queued = true;
        readyBlock = block.number + QUEUE_DELAY_BLOCKS;
    }

    function executeProposal() external {
        require(!paused, "BeanstalkGovernanceMockV4: protocol is paused");
        require(queued, "BeanstalkGovernanceMockV4: not queued");
        require(
            !executed && !canceled,
            "BeanstalkGovernanceMockV4: proposal closed"
        );
        require(
            block.number >= readyBlock,
            "BeanstalkGovernanceMockV4: timelock active"
        );

        executed = true;
        treasury = 0;
    }

    function cancelProposal() external onlyOwnerOrGuardian {
        require(!executed, "BeanstalkGovernanceMockV4: already executed");
        canceled = true;
    }

    function pause() external onlyPauseGuardian {
        paused = true;
    }

    function getTrapSnapshot()
        external
        view
        returns (
            uint256 snapshotProposalForVotes,
            uint256 snapshotProposalThresholdVotes,
            uint256 snapshotSupportVoterCount,
            uint256 snapshotTopSupporterVotes,
            uint256 snapshotQueued,
            uint256 snapshotReadyBlock,
            uint256 snapshotBlock,
            uint256 snapshotPaused,
            uint256 snapshotExecuted,
            uint256 snapshotCanceled
        )
    {
        snapshotProposalForVotes = proposalForVotes;
        snapshotProposalThresholdVotes = proposalThresholdVotes;
        snapshotSupportVoterCount = supportVoterCount;
        snapshotTopSupporterVotes = topSupporterVotes;
        snapshotQueued = queued ? 1 : 0;
        snapshotReadyBlock = readyBlock;
        snapshotBlock = block.number;
        snapshotPaused = paused ? 1 : 0;
        snapshotExecuted = executed ? 1 : 0;
        snapshotCanceled = canceled ? 1 : 0;
    }
}
