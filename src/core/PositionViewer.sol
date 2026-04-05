// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GemachPool} from "./GemachPool.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AdapterRouter} from "./AdapterRouter.sol";

/// @title PositionViewer
/// @notice Read-only helper for querying user positions and global pool state.
///         Deployed once and works with any GemachPool instance.
contract PositionViewer {
    struct UserPositionData {
        uint256 principal;
        uint256 debtShares;
        uint256 currentDebt;
        uint256 collateralValue;
        uint256 currentLtvBps;
        bool isLiquidatable;
        uint256 availableToBorrow;
        uint256 availableToWithdraw;
        bool hasPosition;
    }

    struct GlobalStateData {
        uint256 totalPrincipal;
        uint256 sponsorBackstop;
        uint256 totalDebtShares;
        uint256 debtIndex;
        uint256 totalUserDebt;
        uint256 externalDebt;
        uint256 carryGap;
        uint256 bufferBalance;
        uint256 harvestableSurplus;
        uint256 totalUnderlying;
        uint256 requiredBacking;
        uint256 totalVaultShares;
        bool emergencyMode;
        bool paused;
    }

    // ================================================================
    //                     PER-USER VIEWS
    // ================================================================

    /// @notice Full position data for a user.
    function getUserPosition(address pool, address user) external view returns (UserPositionData memory data) {
        GemachPool p = GemachPool(pool);
        (uint256 principal, uint256 debtShares) = p.positions(user);

        data.principal = principal;
        data.debtShares = debtShares;
        data.currentDebt = p.userDebt(user);
        data.hasPosition = principal > 0 || debtShares > 0;

        if (principal > 0) {
            data.collateralValue = p.userCollateralValue(user);
            data.currentLtvBps = _ltvBps(data.currentDebt, data.collateralValue);
            data.isLiquidatable = data.currentLtvBps > p.liquidationLtvBps();
            data.availableToBorrow = _availableToBorrow(p, principal, debtShares);
            data.availableToWithdraw = _availableToWithdraw(p, principal, debtShares);
        } else if (debtShares > 0) {
            // has debt but no principal — fully liquidatable
            data.isLiquidatable = true;
        }
    }

    /// @notice Current LTV in basis points for a user.
    function currentLtv(address pool, address user) external view returns (uint256) {
        GemachPool p = GemachPool(pool);
        uint256 debt = p.userDebt(user);
        if (debt == 0) return 0;
        uint256 colValue = p.userCollateralValue(user);
        if (colValue == 0) return type(uint256).max;
        return debt * 10000 / colValue;
    }

    /// @notice Total debt for a user in debt-token units.
    function totalDebt(address pool, address user) external view returns (uint256) {
        return GemachPool(pool).userDebt(user);
    }

    /// @notice Whether a user is liquidatable.
    function isLiquidatable(address pool, address user) external view returns (bool) {
        GemachPool p = GemachPool(pool);
        (uint256 principal,) = p.positions(user);
        if (principal == 0) return false;
        uint256 debt = p.userDebt(user);
        if (debt == 0) return false;
        uint256 colValue = p.userCollateralValue(user);
        if (colValue == 0) return true;
        return (debt * 10000 / colValue) > p.liquidationLtvBps();
    }

    /// @notice Maximum additional debt-tokens the user can borrow.
    function availableToBorrow(address pool, address user) external view returns (uint256) {
        GemachPool p = GemachPool(pool);
        (uint256 principal, uint256 debtShares) = p.positions(user);
        return _availableToBorrow(p, principal, debtShares);
    }

    /// @notice Maximum collateral the user can withdraw.
    function availableToWithdraw(address pool, address user) external view returns (uint256) {
        GemachPool p = GemachPool(pool);
        (uint256 principal, uint256 debtShares) = p.positions(user);
        return _availableToWithdraw(p, principal, debtShares);
    }

    /// @notice Collateral value in debt-token units for a user.
    function collateralValue(address pool, address user) external view returns (uint256) {
        return GemachPool(pool).userCollateralValue(user);
    }

    // ================================================================
    //                     GLOBAL VIEWS
    // ================================================================

    /// @notice Full global state snapshot.
    function getGlobalState(address pool) external view returns (GlobalStateData memory data) {
        GemachPool p = GemachPool(pool);
        data.totalPrincipal = p.totalPrincipal();
        data.sponsorBackstop = p.sponsorBackstop();
        data.totalDebtShares = p.totalDebtShares();
        data.debtIndex = p.debtIndex();
        data.totalUserDebt = p.totalUserDebt();
        data.externalDebt = p.externalDebt();
        data.carryGap = p.carryGap();
        data.bufferBalance = p.bufferBalance();
        data.harvestableSurplus = p.harvestableSurplus();
        data.totalUnderlying = p.totalUnderlying();
        data.requiredBacking = p.requiredBacking();
        data.totalVaultShares = p.totalVaultShares();
        data.emergencyMode = p.emergencyMode();
        data.paused = p.paused();
    }

    /// @notice Global utilization: totalUserDebt / totalCollateralValue in bps.
    function utilizationBps(address pool) external view returns (uint256) {
        GemachPool p = GemachPool(pool);
        uint256 totalDebtVal = p.totalUserDebt();
        if (totalDebtVal == 0) return 0;
        uint256 totalColVal = IPriceOracle(p.oracle()).quote(p.totalPrincipal());
        if (totalColVal == 0) return type(uint256).max;
        return totalDebtVal * 10000 / totalColVal;
    }

    /// @notice Check multiple users for liquidatability in one call.
    function batchIsLiquidatable(address pool, address[] calldata users) external view returns (bool[] memory results) {
        GemachPool p = GemachPool(pool);
        uint256 liqLtv = p.liquidationLtvBps();
        results = new bool[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 principal,) = p.positions(users[i]);
            if (principal == 0) continue;
            uint256 debt = p.userDebt(users[i]);
            if (debt == 0) continue;
            uint256 colVal = p.userCollateralValue(users[i]);
            if (colVal == 0) {
                results[i] = true;
                continue;
            }
            results[i] = (debt * 10000 / colVal) > liqLtv;
        }
    }

    // ================================================================
    //                     INTERNAL
    // ================================================================

    function _ltvBps(uint256 debt, uint256 colValue) internal pure returns (uint256) {
        if (debt == 0) return 0;
        if (colValue == 0) return type(uint256).max;
        return debt * 10000 / colValue;
    }

    function _availableToBorrow(GemachPool p, uint256 principal, uint256 debtShares) internal view returns (uint256) {
        if (principal == 0) return 0;
        uint256 colValue = IPriceOracle(p.oracle()).quote(principal);
        uint256 maxDebt = colValue * p.maxBorrowLtvBps() / 10000;
        uint256 currentDebt = debtShares * p.debtIndex() / 1e18;
        return maxDebt > currentDebt ? maxDebt - currentDebt : 0;
    }

    function _availableToWithdraw(GemachPool p, uint256 principal, uint256 debtShares) internal view returns (uint256) {
        if (debtShares == 0) return principal;
        uint256 currentDebt = debtShares * p.debtIndex() / 1e18;
        uint256 maxLtv = p.maxBorrowLtvBps();
        if (maxLtv == 0) return 0;

        // minCollateralValue = currentDebt * 10000 / maxLtv
        uint256 minColValue = currentDebt * 10000 / maxLtv;
        uint256 currentColValue = IPriceOracle(p.oracle()).quote(principal);

        if (currentColValue <= minColValue) return 0;

        // excessValue in debt terms, convert to collateral
        uint256 excessValue = currentColValue - minColValue;
        uint256 oneUnit = 10 ** _decimalsOf(p.collateralToken());
        uint256 pricePerUnit = IPriceOracle(p.oracle()).quote(oneUnit);
        if (pricePerUnit == 0) return 0;

        uint256 withdrawable = excessValue * oneUnit / pricePerUnit;
        return withdrawable > principal ? principal : withdrawable;
    }

    function _decimalsOf(address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && ret.length >= 32) return abi.decode(ret, (uint8));
        return 18;
    }
}
