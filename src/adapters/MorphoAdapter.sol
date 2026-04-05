// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho} from "../interfaces/IMorpho.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @title MorphoAdapter
/// @notice Thin wrapper around a Morpho Blue market for any collateral/loan pair.
contract MorphoAdapter is BaseAdapter {
    using SafeERC20 for IERC20;

    address public immutable MORPHO;
    bytes32 public immutable MARKET_ID;

    IMorpho.MarketParams public marketParams;

    constructor(
        address _authority,
        address _morpho,
        address _collateralToken,
        address _loanToken,
        bytes32 _marketId,
        IMorpho.MarketParams memory _marketParams
    ) BaseAdapter(_authority, _collateralToken, _loanToken) {
        MORPHO = _morpho;
        MARKET_ID = _marketId;
        marketParams = _marketParams;

        IERC20(_collateralToken).forceApprove(_morpho, type(uint256).max);
        IERC20(_loanToken).forceApprove(_morpho, type(uint256).max);
    }

    // -------- mutative --------

    function supplyCollateral(uint256 shares) external override onlyRouter {
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), shares);
        IMorpho(MORPHO).supplyCollateral(marketParams, shares, address(this), "");
    }

    function withdrawCollateral(uint256 shares, address to) external override onlyRouter returns (uint256) {
        IMorpho(MORPHO).withdrawCollateral(marketParams, shares, address(this), to);
        return shares;
    }

    function borrow(uint256 amount, address to) external override onlyRouter returns (uint256) {
        (uint256 borrowed,) = IMorpho(MORPHO).borrow(marketParams, amount, 0, address(this), to);
        return borrowed;
    }

    function repay(uint256 amount) external override onlyRouter returns (uint256) {
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), amount);
        (uint256 repaid,) = IMorpho(MORPHO).repay(marketParams, amount, 0, address(this), "");
        return repaid;
    }

    // -------- views --------

    function totalDebt() external view override returns (uint256) {
        IMorpho.Market memory m = IMorpho(MORPHO).market(MARKET_ID);
        IMorpho.Position memory p = IMorpho(MORPHO).position(MARKET_ID, address(this));
        if (m.totalBorrowShares == 0) return 0;
        return uint256(p.borrowShares) * uint256(m.totalBorrowAssets) / uint256(m.totalBorrowShares);
    }

    function totalCollateralShares() external view override returns (uint256) {
        return uint256(IMorpho(MORPHO).position(MARKET_ID, address(this)).collateral);
    }

    function availableLiquidity() external view override returns (uint256) {
        IMorpho.Market memory m = IMorpho(MORPHO).market(MARKET_ID);
        uint256 supply = uint256(m.totalSupplyAssets);
        uint256 borrows = uint256(m.totalBorrowAssets);
        return supply > borrows ? supply - borrows : 0;
    }

    function withdrawableCollateralShares() external view override returns (uint256) {
        return uint256(IMorpho(MORPHO).position(MARKET_ID, address(this)).collateral);
    }
}
