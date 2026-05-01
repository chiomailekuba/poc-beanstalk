// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ITrap.sol";
import "./BeanstalkMock.sol";

/**
 * @title BeanstalkTrap
 * @notice Drosera Trap that detects suspicious governance supermajority
 *         concentration during a protocol-enforced execution delay window.
 *
 * Design goals:
 *   - Zero off-chain dependencies: collect() reads purely on-chain state.
 *   - Monitor concentration for the current top holder (no pre-known attacker).
 *   - Deterministic: given the same two snapshots, shouldRespond() always
 *     returns the same answer.
 *
 * Detection invariant:
 *   Fire when ALL of the following hold between block N-1 and block N:
 *     1. topHolderStalk[N] >= 67 % of totalStalk[N]   (supermajority reached)
 *     2. topHolderStalk[N] >  topHolderStalk[N-1]     (stake increased this block)
 *     3. topHolderReadyBlock[N] > blockNumber[N]      (inside delay window)
 */
contract BeanstalkTrap is ITrap {
    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant SUPERMAJORITY_NUMERATOR = 67;
    uint256 public constant SUPERMAJORITY_DENOMINATOR = 100;

    // ── State ──────────────────────────────────────────────────────────────
    BeanstalkMock public TARGET;
    address public owner;
    bool public configured;

    modifier onlyOwner() {
        require(msg.sender == owner, "BeanstalkTrap: not owner");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor() {
        owner = msg.sender;
    }

    /// @notice One-time target wiring so deployment does not depend on constructor args.
    function configure(address target_) external onlyOwner {
        require(!configured, "BeanstalkTrap: already configured");
        require(target_ != address(0), "BeanstalkTrap: invalid target");
        TARGET = BeanstalkMock(target_);
        configured = true;
    }

    // ── ITrap: collect ─────────────────────────────────────────────────────

    /**
     * @notice Called by Drosera every block.  Reads the current protocol
     *         snapshot and returns it ABI-encoded.
     * @return Encoded (totalStalk, topHolderStalk, topHolder, topHolderReadyBlock, blockNumber, paused).
     *         Returns empty bytes if the protocol has zero total STALK (not
     *         yet initialised), preventing shouldRespond from receiving
     *         garbage data.
     */
    function collect() external view override returns (bytes memory) {
        if (!configured) return bytes("");

        (
            uint256 total,
            uint256 topStalk,
            address topAddress,
            uint256 topReadyBlock,
            uint256 blockNum,
            bool isPaused
        ) = TARGET.getTrapSnapshot();

        if (total == 0) return bytes("");

        return
            abi.encode(
                total,
                topStalk,
                topAddress,
                topReadyBlock,
                blockNum,
                isPaused
            );
    }

    // ── ITrap: shouldRespond ───────────────────────────────────────────────

    /**
     * @notice Called by Drosera with a sample window of block snapshots.
     *         Drosera ordering is newest-to-oldest:
     *         - data[0] = current block snapshot
     *         - data[1] = previous block snapshot
     * @param data  Array of collect() outputs, one per block in the sample window.
     * @return trigger  True if a governance takeover attempt is detected.
     * @return response ABI-encoded incident report for the vault.
     */
    function shouldRespond(
        bytes[] calldata data
    ) external pure override returns (bool trigger, bytes memory response) {
        if (data.length < 2) return (false, bytes(""));

        bytes calldata currBytes = data[0];
        bytes calldata prevBytes = data[1];

        if (prevBytes.length == 0 || currBytes.length == 0)
            return (false, bytes(""));

        (
            uint256 prevTotal,
            uint256 prevTopStake,
            address prevTopAddress,
            ,
            ,

        ) = abi.decode(
                prevBytes,
                (uint256, uint256, address, uint256, uint256, bool)
            );

        (
            uint256 currTotal,
            uint256 currTopStake,
            address currTopAddress,
            uint256 currTopReadyBlock,
            uint256 currBlock,
            bool currPaused
        ) = abi.decode(
                currBytes,
                (uint256, uint256, address, uint256, uint256, bool)
            );

        if (currPaused) return (false, bytes(""));

        // A holder transition can itself be the suspicious event
        // (attacker overtakes the prior top holder in one block).
        bool topHolderChanged = prevTopAddress != address(0) &&
            prevTopAddress != currTopAddress;

        // Invariant 1: supermajority reached in current block
        bool hasSuperMajority = currTopStake * SUPERMAJORITY_DENOMINATOR >=
            currTotal * SUPERMAJORITY_NUMERATOR;

        // Invariant 2: stake increased this block (rules out stable large holders)
        bool stakeJustIncreased = currTopStake > prevTopStake;

        // Invariant 3: still inside the protocol execution delay window.
        bool insideDelayWindow = currTopReadyBlock > currBlock;

        if (!hasSuperMajority || !stakeJustIncreased || !insideDelayWindow) {
            return (false, bytes(""));
        }

        response = abi.encode(
            topHolderChanged
                ? "GOVERNANCE_DELAY_WINDOW_ATTACK_RISK_TOP_HOLDER_FLIP"
                : "GOVERNANCE_DELAY_WINDOW_ATTACK_RISK",
            currTopAddress,
            currTopStake,
            prevTopStake,
            currTotal,
            currBlock,
            prevTotal,
            currTopReadyBlock
        );

        return (true, response);
    }
}
