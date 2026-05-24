// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeanstalkTypes.sol";

interface IBeanstalkPausable {
    function pause() external;
    function paused() external view returns (bool);
}

contract BeanstalkVaultV3 {
    address public immutable TARGET;
    address public immutable DROSERA_CALLER;
    uint256 public immutable COOLDOWN_BLOCKS;

    uint256 public constant INCIDENT_ENCODED_SIZE = 11 * 32;

    uint256 public lastResponseBlock;
    uint256 public responseCount;

    mapping(bytes32 => bool) public handledIncident;

    event GovernanceTakeoverContained(
        bytes32 indexed incidentId,
        address indexed suspect,
        uint256 currentBlock,
        uint256 reason
    );

    event DuplicateIncidentIgnored(bytes32 indexed incidentId);

    error NotDrosera();
    error WrongInvariant();
    error WrongTarget();
    error InvalidReason();
    error InvalidDelayWindow();
    error CooldownActive();
    error PauseFailed();
    error InvalidPayload();
    error ZeroAddress();

    constructor(
        address target_,
        address droseraCaller_,
        uint256 cooldownBlocks_
    ) {
        if (target_ == address(0) || droseraCaller_ == address(0)) {
            revert ZeroAddress();
        }

        TARGET = target_;
        DROSERA_CALLER = droseraCaller_;
        COOLDOWN_BLOCKS = cooldownBlocks_;
    }

    function executeResponse(bytes calldata rawIncident) external {
        if (msg.sender != DROSERA_CALLER) revert NotDrosera();

        if (rawIncident.length != INCIDENT_ENCODED_SIZE) {
            revert InvalidPayload();
        }

        bytes32 incidentId = keccak256(rawIncident);

        // Idempotent retry behavior.
        if (handledIncident[incidentId]) {
            emit DuplicateIncidentIgnored(incidentId);
            return;
        }

        BeanstalkTypes.Incident memory incident = abi.decode(
            rawIncident,
            (BeanstalkTypes.Incident)
        );

        if (incident.invariantId != BeanstalkTypes.INVARIANT_ID) {
            revert WrongInvariant();
        }

        if (incident.target != TARGET) {
            revert WrongTarget();
        }

        if (
            incident.reason !=
            BeanstalkTypes.REASON_SUPERMAJORITY_DELAY_WINDOW &&
            incident.reason != BeanstalkTypes.REASON_TOP_HOLDER_FLIP
        ) {
            revert InvalidReason();
        }

        if (incident.readyBlock <= incident.currentBlock) {
            revert InvalidDelayWindow();
        }

        if (
            lastResponseBlock != 0 &&
            block.number < lastResponseBlock + COOLDOWN_BLOCKS
        ) {
            revert CooldownActive();
        }

        handledIncident[incidentId] = true;
        lastResponseBlock = block.number;
        responseCount++;

        IBeanstalkPausable(TARGET).pause();

        if (!IBeanstalkPausable(TARGET).paused()) {
            revert PauseFailed();
        }

        emit GovernanceTakeoverContained(
            incidentId,
            incident.suspect,
            incident.currentBlock,
            incident.reason
        );
    }
}
