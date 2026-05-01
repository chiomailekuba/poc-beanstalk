// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeanstalkMock.sol";

/**
 * @title BeanstalkVault
 * @notice Drosera Vault (response contract) for the BeanstalkTrap.
 *
 * When the Trap detects a governance flash-loan supermajority it triggers
 * this vault, which calls BeanstalkMock.pause() to halt the protocol before
 * emergencyCommit() can drain the treasury.
 *
 * A cooldown guard prevents repeated pauses within COOLDOWN_BLOCKS blocks,
 * reducing the cost of a DoS-via-spam attack on the Trap.
 */
contract BeanstalkVault {
    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant COOLDOWN_BLOCKS = 33;

    // ── State ──────────────────────────────────────────────────────────────
    BeanstalkMock public immutable TARGET;
    address public immutable DROSERA_CALLER;
    uint256 public lastResponseBlock;
    uint256 public responseCount;

    // ── Events ─────────────────────────────────────────────────────────────
    event GovernanceTakeoverContained(
        uint256 indexed responseId,
        uint256 indexed blockNumber,
        bytes incidentReport
    );

    modifier onlyDrosera() {
        require(msg.sender == DROSERA_CALLER, "BeanstalkVault: not authorized");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor(address _target, address _droseraCaller) {
        require(_target != address(0), "BeanstalkVault: invalid target");
        require(_droseraCaller != address(0), "BeanstalkVault: invalid caller");
        TARGET = BeanstalkMock(_target);
        DROSERA_CALLER = _droseraCaller;
    }

    // ── Response function (called by Drosera network) ──────────────────────

    /**
     * @notice Drosera calls this when BeanstalkTrap.shouldRespond() returns true.
     * @param reason  ABI-encoded incident report from the Trap.
     */
    function executeResponse(bytes calldata reason) external onlyDrosera {
        // Cooldown deduplication — allow first-ever call (lastResponseBlock == 0)
        require(
            lastResponseBlock == 0 ||
                block.number >= lastResponseBlock + COOLDOWN_BLOCKS,
            "BeanstalkVault: cooldown active"
        );

        lastResponseBlock = block.number;
        responseCount += 1;

        TARGET.pause();

        emit GovernanceTakeoverContained(responseCount, block.number, reason);
    }
}
