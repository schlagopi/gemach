// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketAdapter} from "../interfaces/IMarketAdapter.sol";
import {Auth} from "../utils/Auth.sol";

/// @title BaseAdapter
/// @notice Shared base for all lending-market adapters. Stores the collateral
///         and loan token addresses, the authorized router, and provides the
///         onlyRouter modifier.
abstract contract BaseAdapter is IMarketAdapter, Auth {
    using SafeERC20 for IERC20;

    address public immutable override collateralToken;
    address public immutable override loanToken;
    address public router;

    constructor(address _authority, address _collateralToken, address _loanToken) {
        authority = _authority;
        collateralToken = _collateralToken;
        loanToken = _loanToken;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "not router");
        _;
    }

    /// @notice Set the authorized router. Governance only.
    function setRouter(address _router) external onlyGovernance {
        router = _router;
    }
}
