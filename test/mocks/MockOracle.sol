// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @title MockOracle
/// @notice Morpho-style oracle returning price scaled to 1e36.
///         debtAmount = collateralAmount * price / 1e36
///
///         Default: 1 cbBTC (1e8) = 60,000 USDC (60_000e6).
///         price = 60_000e6 * 1e36 / 1e8 = 60_000e34 = 6e38
contract MockOracle is IPriceOracle {
    uint256 public oraclePrice;

    constructor() {
        // default: 1e8 collateral = 60_000e6 debt
        // price = 60_000e6 * 1e36 / 1e8 = 6e38
        oraclePrice = 6e38;
    }

    /// @notice Set the raw oracle price (1e36-scaled).
    function setRawPrice(uint256 _price) external {
        oraclePrice = _price;
    }

    /// @notice Convenience: set as "1 unit of collateral = X debt tokens"
    ///         where collateralDecimals and debtDecimals are provided.
    function setPrice(uint256 debtPerCollateral, uint8 collateralDecimals, uint8 debtDecimals) external {
        // debtPerCollateral is in debt-token units for 1 full unit of collateral
        // price = debtPerCollateral * 1e36 / (10 ** collateralDecimals)
        // but debtPerCollateral is already in debt decimals
        oraclePrice = debtPerCollateral * 1e36 / (10 ** collateralDecimals);
    }

    /// @notice Convenience: set price as "1e8 collateral = X USDC"
    ///         (matches old test pattern with 8-decimal collateral, 6-decimal debt).
    function setBtcPrice(uint256 usdcPer1Btc) external {
        // price = usdcPer1Btc * 1e36 / 1e8
        oraclePrice = usdcPer1Btc * 1e36 / 1e8;
    }

    function price() external view override returns (uint256) {
        return oraclePrice;
    }
}
