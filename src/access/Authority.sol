// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/// @title Authority
/// @notice Central role registry for the Gemach protocol, built on OZ
///         AccessControlEnumerable. All protocol contracts reference this
///         single contract for authorization checks.
contract Authority is AccessControlEnumerable {
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice The deployer receives DEFAULT_ADMIN_ROLE and GOVERNANCE_ROLE.
    ///         GOVERNANCE_ROLE is the admin for KEEPER and GUARDIAN roles.
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);

        // GOVERNANCE_ROLE manages KEEPER and GUARDIAN
        _setRoleAdmin(KEEPER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, GOVERNANCE_ROLE);
    }
}
