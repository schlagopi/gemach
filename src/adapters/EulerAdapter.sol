// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketAdapter} from "./IMarketAdapter.sol";
import {Auth} from "../utils/Auth.sol";

// -------- Euler-specific interfaces (minimal) --------

/// @notice Minimal EVC-compatible Euler V2 vault interface.
interface IEulerVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function borrow(uint256 assets, address receiver) external returns (uint256 shares);
    function repay(uint256 assets, address receiver) external returns (uint256 shares);

    function totalBorrows() external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);

    function interestRate() external view returns (uint256);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
}

/// @title EulerAdapter
/// @notice Thin wrapper around an Euler V2 vault pair (collateral vault + borrow vault)
///         for any collateral/loan pair.
contract EulerAdapter is IMarketAdapter, Auth {
    using SafeERC20 for IERC20;

    address public immutable collateralVault;
    address public immutable borrowVault;
    address public immutable override collateralToken;
    address public immutable override loanToken;

    address public router;

    constructor(
        address _authority,
        address _collateralVault,
        address _borrowVault,
        address _collateralToken,
        address _loanToken
    ) {
        authority = _authority;
        collateralVault = _collateralVault;
        borrowVault = _borrowVault;
        collateralToken = _collateralToken;
        loanToken = _loanToken;

        IERC20(_collateralToken).forceApprove(_collateralVault, type(uint256).max);
        IERC20(_loanToken).forceApprove(_borrowVault, type(uint256).max);
    }

    modifier onlyRouter() {
        require(msg.sender == router, "not router");
        _;
    }

    /// @notice Set the authorized router. Governance only.
    function setRouter(address _router) external onlyGovernance {
        router = _router;
    }

    // -------- IMarketAdapter mutative --------

    /// @inheritdoc IMarketAdapter
    function supplyCollateral(uint256 shares) external override onlyRouter {
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), shares);
        IEulerVault(collateralVault).deposit(shares, address(this));
    }

    /// @inheritdoc IMarketAdapter
    function withdrawCollateral(uint256 shares, address to) external override onlyRouter returns (uint256) {
        IEulerVault(collateralVault).withdraw(shares, to, address(this));
        return shares;
    }

    /// @inheritdoc IMarketAdapter
    function borrow(uint256 amount, address to) external override onlyRouter returns (uint256) {
        IEulerVault(borrowVault).borrow(amount, to);
        return amount;
    }

    /// @inheritdoc IMarketAdapter
    function repay(uint256 amount) external override onlyRouter returns (uint256) {
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), amount);
        IEulerVault(borrowVault).repay(amount, address(this));
        return amount;
    }

    // -------- IMarketAdapter views --------

    /// @inheritdoc IMarketAdapter
    function totalDebt() external view override returns (uint256) {
        return IEulerVault(borrowVault).debtOf(address(this));
    }

    /// @inheritdoc IMarketAdapter
    function totalCollateralShares() external view override returns (uint256) {
        uint256 vaultShares = IEulerVault(collateralVault).balanceOf(address(this));
        return IEulerVault(collateralVault).convertToAssets(vaultShares);
    }

    /// @inheritdoc IMarketAdapter
    function currentBorrowRate() external view override returns (uint256) {
        return IEulerVault(borrowVault).interestRate();
    }

    /// @inheritdoc IMarketAdapter
    function availableLiquidity() external view override returns (uint256) {
        uint256 total = IEulerVault(borrowVault).totalAssets();
        uint256 borrows = IEulerVault(borrowVault).totalBorrows();
        return total > borrows ? total - borrows : 0;
    }

    /// @inheritdoc IMarketAdapter
    function withdrawableCollateralShares() external view override returns (uint256) {
        return IEulerVault(collateralVault).maxWithdraw(address(this));
    }
}
