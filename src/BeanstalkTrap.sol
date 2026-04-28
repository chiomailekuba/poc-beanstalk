// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/ITrap.sol";
import "./BeanstalkMock.sol";

/**
 * @title BeanstalkTrap
 * @notice Drosera Trap that detects a governance flash-loan supermajority
 *         accumulation on the Beanstalk Farms protocol.
 *
 * Design goals:
 *   - Zero off-chain dependencies: collect() reads purely on-chain state.
 *   - Minimal, auditable logic: two pure functions, no storage writes.
 *   - Deterministic: given the same two snapshots, shouldRespond() always
 *     returns the same answer.
 *
 * Detection invariant:
 *   Fire when ALL of the following hold between block N-1 and block N:
 *     1. candidateStalk[N] >= 67 % of totalStalk[N]  (supermajority reached)
 *     2. candidateStalk[N] >  candidateStalk[N-1]     (stake increased this block)
 *
 *   Condition 2 avoids false positives for addresses that legitimately hold
 *   large STALK positions across many blocks.
 */
contract BeanstalkTrap is ITrap {
    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant SUPERMAJORITY_NUMERATOR = 67;
    uint256 public constant SUPERMAJORITY_DENOMINATOR = 100;

    // ── Immutables ─────────────────────────────────────────────────────────
    BeanstalkMock public immutable TARGET;
    address public immutable WATCHED_CANDIDATE;

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor(address _target, address _candidate) {
        TARGET = BeanstalkMock(_target);
        WATCHED_CANDIDATE = _candidate;
    }

    // ── ITrap: collect ─────────────────────────────────────────────────────

    /**
     * @notice Called by Drosera every block.  Reads the current protocol
     *         snapshot and returns it ABI-encoded.
     * @return Encoded (totalStalk, candidateStalk, candidate, blockNumber).
     *         Returns empty bytes if the protocol has zero total STALK (not
     *         yet initialised), preventing shouldRespond from receiving
     *         garbage data.
     */
    function collect() external view override returns (bytes memory) {
        (
            uint256 total,
            uint256 candidateStalk,
            address candidate,
            uint256 blockNum
        ) = TARGET.getTrapSnapshot(WATCHED_CANDIDATE);

        if (total == 0) return bytes("");

        return abi.encode(total, candidateStalk, candidate, blockNum);
    }

    // ── ITrap: shouldRespond ───────────────────────────────────────────────

    /**
     * @notice Called by Drosera with the last N block snapshots.
     *         We compare data[len-2] (previous block) vs data[len-1] (current).
     * @param data  Array of collect() outputs, one per block in the sample window.
     * @return trigger  True if a governance takeover attempt is detected.
     * @return response ABI-encoded incident report for the vault.
     */
    function shouldRespond(
        bytes[] calldata data
    ) external pure override returns (bool trigger, bytes memory response) {
        uint256 len = data.length;
        if (len < 2) return (false, bytes(""));

        bytes calldata prevBytes = data[len - 2];
        bytes calldata currBytes = data[len - 1];

        if (prevBytes.length == 0 || currBytes.length == 0)
            return (false, bytes(""));

        (uint256 prevTotal, uint256 prevCandidate, , ) = abi.decode(
            prevBytes,
            (uint256, uint256, address, uint256)
        );

        (
            uint256 currTotal,
            uint256 currCandidate,
            address currAddress,
            uint256 currBlock
        ) = abi.decode(currBytes, (uint256, uint256, address, uint256));

        // Invariant 1: supermajority reached in current block
        bool hasSuperMajority = currCandidate * SUPERMAJORITY_DENOMINATOR >=
            currTotal * SUPERMAJORITY_NUMERATOR;

        // Invariant 2: stake increased this block (rules out stable large holders)
        bool stakeJustIncreased = currCandidate > prevCandidate;

        if (!hasSuperMajority || !stakeJustIncreased) {
            return (false, bytes(""));
        }

        response = abi.encode(
            "GOVERNANCE_FLASH_LOAN_DETECTED",
            currAddress,
            currCandidate,
            prevCandidate,
            currTotal,
            currBlock,
            prevTotal
        );

        return (true, response);
    }
}
