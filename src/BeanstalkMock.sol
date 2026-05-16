// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BeanstalkMock
 * @notice Minimal on-chain replica of the Beanstalk Farms protocol that
 *         reproduces the April 17 2022 governance flash-loan attack surface.
 *
 * Attack summary (real event):
 *   - Attacker flash-borrowed enough STALK to hold 67.08 % of total supply
 *   - Called emergencyCommit() in the same block to pass BIP-18
 *   - Drained ~$182 M from the protocol treasury
 *
 * This mock lets the BeanstalkTrap detect a supermajority accumulation
 * between two consecutive blocks before emergencyCommit() can fire.
 */
contract BeanstalkMock {
    // ── State ──────────────────────────────────────────────────────────────
    address public owner;
    address public pauseGuardian;
    uint256 public totalStalk;
    uint256 public treasury;
    bool public paused;
    address public topHolder;
    uint256 public topHolderStalk;

    mapping(address => uint256) public stalk;
    mapping(address => uint256) public emergencyReadyBlock;

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant INITIAL_TOTAL_STALK = 10_000 ether;
    uint256 public constant INITIAL_TREASURY = 182_000_000 ether;

    // Attacker flash-acquires this amount in a single tx.
    // Math: need F * 100 >= (10_000 + F) * 67  =>  33F >= 670_000  =>  F >= 20_304
    // Using 20_400 gives a comfortable supermajority of ~67.1 %.
    uint256 public constant FLASH_STALK_AMOUNT = 20_400 ether;
    uint256 public constant MIN_EXECUTION_DELAY_BLOCKS = 1;

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor() {
        owner = msg.sender;
        pauseGuardian = msg.sender;
        totalStalk = INITIAL_TOTAL_STALK;
        treasury = INITIAL_TREASURY;
        paused = false;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "BeanstalkMock: not owner");
        _;
    }

    modifier onlyPauseGuardian() {
        require(msg.sender == pauseGuardian, "BeanstalkMock: not guardian");
        _;
    }

    // ── Helpers for tests ──────────────────────────────────────────────────

    /// @notice Seed a normal stakeholder with some STALK (used in test setup)
    function seedStalk(address holder, uint256 amount) external {
        stalk[holder] += amount;
        totalStalk += amount;
        _updateTopHolder(holder);
    }

    /// @notice Updates the contract authorized to pause governance.
    function setPauseGuardian(address guardian) external onlyOwner {
        require(guardian != address(0), "BeanstalkMock: invalid guardian");
        pauseGuardian = guardian;
    }

    // ── Attack surface ─────────────────────────────────────────────────────

    /// @notice Simulates a flash-loan giving the caller a governance supermajority.
    ///         In the real attack this was done via an Aave flash loan.
    function acquireFlashVotes() external {
        require(!paused, "BeanstalkMock: protocol is paused");
        stalk[msg.sender] += FLASH_STALK_AMOUNT;
        totalStalk += FLASH_STALK_AMOUNT;
        _updateTopHolder(msg.sender);
    }

    /// @notice Simulates benign/gradual governance accumulation.
    function acquireVotesSlowly(address holder, uint256 amount) external {
        require(!paused, "BeanstalkMock: protocol is paused");
        stalk[holder] += amount;
        totalStalk += amount;
        _updateTopHolder(holder);
    }

    /// @notice Queues emergency execution and enforces a reaction window.
    function queueEmergencyCommit() external {
        require(!paused, "BeanstalkMock: protocol is paused");
        require(
            stalk[msg.sender] * 100 >= totalStalk * 67,
            "BeanstalkMock: insufficient governance power"
        );

        emergencyReadyBlock[msg.sender] =
            block.number +
            MIN_EXECUTION_DELAY_BLOCKS;
    }

    /// @notice Mirrors the real emergencyCommit() — drains treasury if caller
    ///         holds a supermajority (≥ 67 %) of total STALK.
    function emergencyCommit() external {
        require(!paused, "BeanstalkMock: protocol is paused");
        require(
            stalk[msg.sender] * 100 >= totalStalk * 67,
            "BeanstalkMock: insufficient governance power"
        );
        require(
            emergencyReadyBlock[msg.sender] != 0,
            "BeanstalkMock: commit not queued"
        );
        require(
            block.number >= emergencyReadyBlock[msg.sender],
            "BeanstalkMock: execution delay active"
        );
        treasury = 0;
    }

    // ── Mitigation surface ─────────────────────────────────────────────────

    /// @notice Called by BeanstalkVault when the Trap fires.
    function pause() external onlyPauseGuardian {
        paused = true;
    }

    // ── Trap read surface ──────────────────────────────────────────────────

    /// @notice Returns the snapshot data that BeanstalkTrap.collect() reads
    ///         every block.
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
        )
    {
        snapshotTotalStalk = totalStalk;
        snapshotTopHolderStalk = topHolderStalk;
        snapshotTopHolder = topHolder;
        snapshotTopHolderReadyBlock = emergencyReadyBlock[topHolder];
        snapshotBlock = block.number;
        snapshotPaused = paused;
    }

    function _updateTopHolder(address holder) internal {
        uint256 holderStalk = stalk[holder];
        if (holderStalk > topHolderStalk) {
            topHolderStalk = holderStalk;
            topHolder = holder;
        }
    }
}
