// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GemachPool} from "../core/GemachPool.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title Positions
/// @notice Library for querying user positions and global pool state.
library Positions {
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
        uint256 protocolBuffer;
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
    function getUserPosition(GemachPool p, address user) internal view returns (UserPositionData memory data) {
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
            data.isLiquidatable = true;
        }
    }

    /// @notice Current LTV in basis points for a user.
    function currentLtv(GemachPool p, address user) internal view returns (uint256) {
        uint256 debt = p.userDebt(user);
        if (debt == 0) return 0;
        uint256 colValue = p.userCollateralValue(user);
        if (colValue == 0) return type(uint256).max;
        return debt * 10000 / colValue;
    }

    /// @notice Total debt for a user in debt-token units.
    function totalDebt(GemachPool p, address user) internal view returns (uint256) {
        return p.userDebt(user);
    }

    /// @notice Whether a user is liquidatable.
    function isLiquidatable(GemachPool p, address user) internal view returns (bool) {
        (uint256 principal,) = p.positions(user);
        if (principal == 0) return false;
        uint256 debt = p.userDebt(user);
        if (debt == 0) return false;
        uint256 colValue = p.userCollateralValue(user);
        if (colValue == 0) return true;
        return (debt * 10000 / colValue) > p.liquidationLtvBps();
    }

    /// @notice Maximum additional debt-tokens the user can borrow.
    function availableToBorrow(GemachPool p, address user) internal view returns (uint256) {
        (uint256 principal, uint256 debtShares) = p.positions(user);
        return _availableToBorrow(p, principal, debtShares);
    }

    /// @notice Maximum collateral the user can withdraw.
    function availableToWithdraw(GemachPool p, address user) internal view returns (uint256) {
        (uint256 principal, uint256 debtShares) = p.positions(user);
        return _availableToWithdraw(p, principal, debtShares);
    }

    /// @notice Collateral value in debt-token units for a user.
    function collateralValue(GemachPool p, address user) internal view returns (uint256) {
        return p.userCollateralValue(user);
    }

    // ================================================================
    //                     GLOBAL VIEWS
    // ================================================================

    /// @notice Full global state snapshot.
    function getGlobalState(GemachPool p) internal view returns (GlobalStateData memory data) {
        data.totalPrincipal = p.totalPrincipal();
        data.sponsorBackstop = p.sponsorBackstop();
        data.totalDebtShares = p.totalDebtShares();
        data.debtIndex = p.debtIndex();
        data.totalUserDebt = p.totalUserDebt();
        data.externalDebt = p.externalDebt();
        data.carryGap = p.carryGap();
        data.protocolBuffer = p.protocolBuffer();
        data.harvestableSurplus = p.harvestableSurplus();
        data.totalUnderlying = p.totalUnderlying();
        data.requiredBacking = p.requiredBacking();
        data.totalVaultShares = p.totalVaultShares();
        data.emergencyMode = p.emergencyMode();
        data.paused = p.paused();
    }

    /// @notice Global utilization: totalUserDebt / totalCollateralValue in bps.
    function utilizationBps(GemachPool p) internal view returns (uint256) {
        uint256 totalDebtVal = p.totalUserDebt();
        if (totalDebtVal == 0) return 0;
        uint256 totalColVal = IPriceOracle(p.oracle()).quote(p.totalPrincipal());
        if (totalColVal == 0) return type(uint256).max;
        return totalDebtVal * 10000 / totalColVal;
    }

    /// @notice Check multiple users for liquidatability in one call.
    function batchIsLiquidatable(GemachPool p, address[] calldata users) internal view returns (bool[] memory results) {
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

    function _ltvBps(uint256 debt, uint256 colValue) private pure returns (uint256) {
        if (debt == 0) return 0;
        if (colValue == 0) return type(uint256).max;
        return debt * 10000 / colValue;
    }

    function _availableToBorrow(GemachPool p, uint256 principal, uint256 debtShares) private view returns (uint256) {
        if (principal == 0) return 0;
        uint256 colValue = IPriceOracle(p.oracle()).quote(principal);
        uint256 maxDebt = colValue * p.maxBorrowLtvBps() / 10000;
        uint256 currentDebt = debtShares * p.debtIndex() / 1e18;
        return maxDebt > currentDebt ? maxDebt - currentDebt : 0;
    }

    function _availableToWithdraw(GemachPool p, uint256 principal, uint256 debtShares) private view returns (uint256) {
        if (debtShares == 0) return principal;
        uint256 currentDebt = debtShares * p.debtIndex() / 1e18;
        uint256 maxLtv = p.maxBorrowLtvBps();
        if (maxLtv == 0) return 0;

        uint256 minColValue = currentDebt * 10000 / maxLtv;
        uint256 currentColValue = IPriceOracle(p.oracle()).quote(principal);
        if (currentColValue <= minColValue) return 0;

        uint256 excessValue = currentColValue - minColValue;
        uint256 oneUnit = 10 ** p.COLLATERAL_DECIMALS();
        uint256 pricePerUnit = IPriceOracle(p.oracle()).quote(oneUnit);
        if (pricePerUnit == 0) return 0;

        uint256 withdrawable = excessValue * oneUnit / pricePerUnit;
        return withdrawable > principal ? principal : withdrawable;
    }
}
