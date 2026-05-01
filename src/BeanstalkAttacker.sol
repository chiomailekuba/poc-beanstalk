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
 * This demo contract provides both an atomic path (which should fail once
 * delay controls are enabled) and a delayed path that mirrors execution after
 * a governance reaction window.
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

    /// @notice Step 2 – queue delayed emergency execution.
    function queueEmergencyCommit() external {
        TARGET.queueEmergencyCommit();
    }

    /// @notice Step 2 – drain treasury via emergencyCommit().
    function drainTreasury() external {
        TARGET.emergencyCommit();
    }

    /// @notice Attempts an atomic path. This should revert when delay controls
    ///         are active because queue + execute occur in the same block.
    function atomicAttack() external {
        TARGET.acquireFlashVotes();
        TARGET.queueEmergencyCommit();
        TARGET.emergencyCommit();
    }
}
