// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEulerVault} from "../interfaces/IEulerVault.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @title EulerAdapter
/// @notice Thin wrapper around an Euler V2 vault pair (collateral vault + borrow vault).
contract EulerAdapter is BaseAdapter {
    using SafeERC20 for IERC20;

    address public immutable COLLATERAL_VAULT;
    address public immutable BORROW_VAULT;

    constructor(
        address _authority,
        address _collateralVault,
        address _borrowVault,
        address _collateralToken,
        address _loanToken
    ) BaseAdapter(_authority, _collateralToken, _loanToken) {
        COLLATERAL_VAULT = _collateralVault;
        BORROW_VAULT = _borrowVault;

        IERC20(_collateralToken).forceApprove(_collateralVault, type(uint256).max);
        IERC20(_loanToken).forceApprove(_borrowVault, type(uint256).max);
    }

    // -------- mutative --------

    function supplyCollateral(uint256 shares) external override onlyRouter {
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), shares);
        IEulerVault(COLLATERAL_VAULT).deposit(shares, address(this));
    }

    function withdrawCollateral(uint256 shares, address to) external override onlyRouter returns (uint256) {
        IEulerVault(COLLATERAL_VAULT).withdraw(shares, to, address(this));
        return shares;
    }

    function borrow(uint256 amount, address to) external override onlyRouter returns (uint256) {
        IEulerVault(BORROW_VAULT).borrow(amount, to);
        return amount;
    }

    function repay(uint256 amount) external override onlyRouter returns (uint256) {
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), amount);
        IEulerVault(BORROW_VAULT).repay(amount, address(this));
        return amount;
    }

    // -------- views --------

    function totalDebt() external view override returns (uint256) {
        return IEulerVault(BORROW_VAULT).debtOf(address(this));
    }

    function totalCollateralShares() external view override returns (uint256) {
        uint256 vaultShares = IEulerVault(COLLATERAL_VAULT).balanceOf(address(this));
        return IEulerVault(COLLATERAL_VAULT).convertToAssets(vaultShares);
    }

    function availableLiquidity() external view override returns (uint256) {
        uint256 total = IEulerVault(BORROW_VAULT).totalAssets();
        uint256 borrows = IEulerVault(BORROW_VAULT).totalBorrows();
        return total > borrows ? total - borrows : 0;
    }

    function withdrawableCollateralShares() external view override returns (uint256) {
        return IEulerVault(COLLATERAL_VAULT).maxWithdraw(address(this));
    }
}
