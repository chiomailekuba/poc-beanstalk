// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeanstalkTypesV4.sol";

interface IBeanstalkGovernance {
    function pause() external;
    function paused() external view returns (bool);
    function cancelProposal() external;
    function canceled() external view returns (bool);
}

contract BeanstalkVaultV4 {
    address public immutable TARGET;
    address public immutable DROSERA_CALLER;
    uint256 public immutable COOLDOWN_BLOCKS;

    uint256 public constant INCIDENT_ENCODED_SIZE = 11 * 32;

    uint256 public lastResponseBlock;
    uint256 public responseCount;

    mapping(bytes32 => bool) public handledIncident;

    event GovernanceTakeoverContained(
        bytes32 indexed incidentId,
        uint256 indexed currentBlock,
        uint256 reason
    );
    event DuplicateIncidentIgnored(bytes32 indexed incidentId);

    error NotDrosera();
    error InvalidPayload();
    error WrongInvariant();
    error WrongTarget();
    error InvalidReason();
    error InvalidDelayWindow();
    error InvalidThresholdCross();
    error CooldownActive();
    error PauseFailed();
    error CancelFailed();

    constructor(
        address target_,
        address droseraCaller_,
        uint256 cooldownBlocks_
    ) {
        require(target_ != address(0), "invalid target");
        require(droseraCaller_ != address(0), "invalid caller");
        TARGET = target_;
        DROSERA_CALLER = droseraCaller_;
        COOLDOWN_BLOCKS = cooldownBlocks_;
    }

    function executeResponse(bytes calldata rawIncident) external {
        if (msg.sender != DROSERA_CALLER) revert NotDrosera();
        if (rawIncident.length != INCIDENT_ENCODED_SIZE)
            revert InvalidPayload();

        bytes32 incidentId = keccak256(rawIncident);
        if (handledIncident[incidentId]) {
            emit DuplicateIncidentIgnored(incidentId);
            return;
        }

        BeanstalkTypesV4.Incident memory incident = abi.decode(
            rawIncident,
            (BeanstalkTypesV4.Incident)
        );

        if (incident.invariantId != BeanstalkTypesV4.INVARIANT_ID)
            revert WrongInvariant();
        if (incident.target != TARGET) revert WrongTarget();

        if (
            incident.reason !=
            BeanstalkTypesV4.REASON_THRESHOLD_CROSS_DELAY_WINDOW &&
            incident.reason !=
            BeanstalkTypesV4.REASON_COORDINATED_MULTI_SUPPORTER &&
            incident.reason != BeanstalkTypesV4.REASON_SINGLE_WHALE_SUPPORT
        ) {
            revert InvalidReason();
        }

        if (incident.readyBlock <= incident.currentBlock)
            revert InvalidDelayWindow();

        if (
            incident.currentForVotes < incident.thresholdVotes ||
            incident.previousForVotes >= incident.thresholdVotes
        ) {
            revert InvalidThresholdCross();
        }

        if (
            lastResponseBlock != 0 &&
            block.number < lastResponseBlock + COOLDOWN_BLOCKS
        ) {
            revert CooldownActive();
        }

        handledIncident[incidentId] = true;
        lastResponseBlock = block.number;
        responseCount += 1;

        IBeanstalkGovernance(TARGET).pause();

        if (!IBeanstalkGovernance(TARGET).paused()) {
            revert PauseFailed();
        }

        IBeanstalkGovernance(TARGET).cancelProposal();

        if (!IBeanstalkGovernance(TARGET).canceled()) {
            revert CancelFailed();
        }

        emit GovernanceTakeoverContained(
            incidentId,
            incident.currentBlock,
            incident.reason
        );
    }
}
