// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeanstalkMock.sol";

/**
 * @title BeanstalkAttacker
 * @notice Simulates the April 17 2022 Beanstalk attacker.
 *
 * The real attacker flash-borrowed enough STALK in a single transaction to
 * hold a 67.08 % governance supermajority, called emergencyCommit() to pass
 * BIP-18, and drained ~$182 M from the protocol treasury — all in one block.
 *
 * This contract replicates that sequence so Foundry tests can demonstrate:
 *   - WITHOUT Drosera: the attack succeeds (treasury → 0).
 *   - WITH Drosera:    the Trap fires between acquireFlashVotes() and
 *                      emergencyCommit(), the Vault pauses the protocol, and
 *                      the treasury remains intact.
 */
contract BeanstalkAttacker {
    BeanstalkMock public immutable TARGET;

    constructor(address _target) {
        TARGET = BeanstalkMock(_target);
    }

    /// @notice Step 1 – flash-acquire governance supermajority.
    function acquireFlashVotes() external {
        TARGET.acquireFlashVotes();
    }

    /// @notice Step 2 – drain treasury via emergencyCommit().
    function drainTreasury() external {
        TARGET.emergencyCommit();
    }

    /// @notice Runs both steps atomically (used in the baseline test that
    ///         proves the attack works WITHOUT Drosera protection).
    function atomicAttack() external {
        TARGET.acquireFlashVotes();
        TARGET.emergencyCommit();
    }
}
