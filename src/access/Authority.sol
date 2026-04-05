// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Authority
/// @notice Central role registry for the Gemach protocol. All protocol
///         contracts reference this single contract for authorization checks.
contract Authority {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    mapping(bytes32 => EnumerableSet.AddressSet) private _members;

    /// @notice The deployer is auto-granted GOVERNANCE_ROLE.
    constructor() {
        _members[GOVERNANCE_ROLE].add(msg.sender);
    }

    // -------- views --------

    /// @notice Returns true if `account` holds `role`.
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _members[role].contains(account);
    }

    /// @notice Returns the member at `index` for the given `role`.
    function getRoleMember(bytes32 role, uint256 index) external view returns (address) {
        return _members[role].at(index);
    }

    /// @notice Returns the number of members holding `role`.
    function getRoleMemberCount(bytes32 role) external view returns (uint256) {
        return _members[role].length();
    }

    // -------- mutations --------

    /// @notice Grant `role` to `account`. Only callable by governance.
    function grantRole(bytes32 role, address account) external {
        require(_members[GOVERNANCE_ROLE].contains(msg.sender), "not governance");
        _members[role].add(account);
    }

    /// @notice Revoke `role` from `account`. Only callable by governance.
    function revokeRole(bytes32 role, address account) external {
        require(_members[GOVERNANCE_ROLE].contains(msg.sender), "not governance");
        _members[role].remove(account);
    }
}
