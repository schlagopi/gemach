// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Auth
/// @notice Tiny mixin that stores the authority address and provides
///         require-based auth modifiers. Protocol contracts inherit this.
interface IAuthority {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

abstract contract Auth {
    address public authority;

    bytes32 internal constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    modifier onlyGovernance() {
        require(IAuthority(authority).hasRole(GOVERNANCE_ROLE, msg.sender), "not governance");
        _;
    }

    modifier onlyKeeper() {
        require(
            IAuthority(authority).hasRole(KEEPER_ROLE, msg.sender)
                || IAuthority(authority).hasRole(GOVERNANCE_ROLE, msg.sender),
            "not keeper"
        );
        _;
    }

    modifier onlyGuardian() {
        require(
            IAuthority(authority).hasRole(GUARDIAN_ROLE, msg.sender)
                || IAuthority(authority).hasRole(GOVERNANCE_ROLE, msg.sender),
            "not guardian"
        );
        _;
    }
}
