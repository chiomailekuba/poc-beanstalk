// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BeanstalkGovernanceMockV4 {
    address public owner;
    address public pauseGuardian;

    uint256 public treasury;
    bool public paused;

    uint256 public activeProposalId;
    uint256 public nextProposalId = 1;

    uint256 public constant INITIAL_TREASURY = 182_000_000 ether;
    uint256 public constant QUEUE_DELAY_BLOCKS = 1;

    struct Proposal {
        uint256 id;
        address proposer;
        address target;
        bytes32 calldataHash;
        uint256 forVotes;
        uint256 thresholdVotes;
        uint256 supportVoterCount;
        uint256 topSupporterVotes;
        bool queued;
        uint256 readyBlock;
        bool executed;
        bool canceled;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => uint256))
        public proposalSupporterVotes;

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
        address target,
        bytes calldata actionData,
        uint256 thresholdVotes_
    ) external onlyOwner returns (uint256 proposalId) {
        require(
            target != address(0),
            "BeanstalkGovernanceMockV4: invalid target"
        );
        require(
            thresholdVotes_ > 0,
            "BeanstalkGovernanceMockV4: invalid threshold"
        );

        proposalId = nextProposalId++;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            target: target,
            calldataHash: keccak256(actionData),
            forVotes: 0,
            thresholdVotes: thresholdVotes_,
            supportVoterCount: 0,
            topSupporterVotes: 0,
            queued: false,
            readyBlock: 0,
            executed: false,
            canceled: false
        });

        activeProposalId = proposalId;
    }

    function supportProposal(uint256 votes) external {
        require(!paused, "BeanstalkGovernanceMockV4: protocol is paused");
        Proposal storage p = proposals[activeProposalId];
        require(p.id != 0, "BeanstalkGovernanceMockV4: no active proposal");
        require(
            !p.executed && !p.canceled,
            "BeanstalkGovernanceMockV4: proposal closed"
        );
        require(votes > 0, "BeanstalkGovernanceMockV4: invalid votes");

        if (proposalSupporterVotes[activeProposalId][msg.sender] == 0) {
            p.supportVoterCount += 1;
        }

        proposalSupporterVotes[activeProposalId][msg.sender] += votes;
        p.forVotes += votes;

        if (
            proposalSupporterVotes[activeProposalId][msg.sender] >
            p.topSupporterVotes
        ) {
            p.topSupporterVotes = proposalSupporterVotes[activeProposalId][
                msg.sender
            ];
        }
    }

    function queueProposal() external {
        require(!paused, "BeanstalkGovernanceMockV4: protocol is paused");
        Proposal storage p = proposals[activeProposalId];
        require(p.id != 0, "BeanstalkGovernanceMockV4: no active proposal");
        require(
            !p.executed && !p.canceled,
            "BeanstalkGovernanceMockV4: proposal closed"
        );
        require(!p.queued, "BeanstalkGovernanceMockV4: already queued");
        require(
            p.forVotes >= p.thresholdVotes,
            "BeanstalkGovernanceMockV4: threshold not met"
        );

        p.queued = true;
        p.readyBlock = block.number + QUEUE_DELAY_BLOCKS;
    }

    function executeProposal() external {
        require(!paused, "BeanstalkGovernanceMockV4: protocol is paused");
        Proposal storage p = proposals[activeProposalId];
        require(p.id != 0, "BeanstalkGovernanceMockV4: no active proposal");
        require(p.queued, "BeanstalkGovernanceMockV4: not queued");
        require(
            !p.executed && !p.canceled,
            "BeanstalkGovernanceMockV4: proposal closed"
        );
        require(
            block.number >= p.readyBlock,
            "BeanstalkGovernanceMockV4: timelock active"
        );

        p.executed = true;
        treasury = 0;
    }

    function cancelProposal(uint256 proposalId) external onlyOwnerOrGuardian {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "BeanstalkGovernanceMockV4: proposal missing");
        require(!p.executed, "BeanstalkGovernanceMockV4: already executed");
        require(!p.canceled, "BeanstalkGovernanceMockV4: already canceled");
        p.canceled = true;
    }

    function proposalCanceled(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].canceled;
    }

    function pause() external onlyPauseGuardian {
        paused = true;
    }

    // Compatibility getters — proxy active proposal state.
    function proposalForVotes() external view returns (uint256) {
        return proposals[activeProposalId].forVotes;
    }

    function proposalThresholdVotes() external view returns (uint256) {
        return proposals[activeProposalId].thresholdVotes;
    }

    function supportVoterCount() external view returns (uint256) {
        return proposals[activeProposalId].supportVoterCount;
    }

    function topSupporterVotes() external view returns (uint256) {
        return proposals[activeProposalId].topSupporterVotes;
    }

    function canceled() external view returns (bool) {
        return proposals[activeProposalId].canceled;
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
            uint256 snapshotCanceled,
            uint256 snapshotProposalId,
            address snapshotProposer,
            address snapshotProposalTarget,
            bytes32 snapshotProposalCalldataHash
        )
    {
        Proposal storage p = proposals[activeProposalId];
        snapshotProposalForVotes = p.forVotes;
        snapshotProposalThresholdVotes = p.thresholdVotes;
        snapshotSupportVoterCount = p.supportVoterCount;
        snapshotTopSupporterVotes = p.topSupporterVotes;
        snapshotQueued = p.queued ? 1 : 0;
        snapshotReadyBlock = p.readyBlock;
        snapshotBlock = block.number;
        snapshotPaused = paused ? 1 : 0;
        snapshotExecuted = p.executed ? 1 : 0;
        snapshotCanceled = p.canceled ? 1 : 0;
        snapshotProposalId = p.id;
        snapshotProposer = p.proposer;
        snapshotProposalTarget = p.target;
        snapshotProposalCalldataHash = p.calldataHash;
    }
}
