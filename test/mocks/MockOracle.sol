// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @title MockOracle
/// @notice Returns a configurable collateral/debt price for testing.
///         Default: 1 BTC (1e8 units) = 60,000 USDC (60_000e6).
contract MockOracle is IPriceOracle {
    /// @notice Price of one full unit of collateral in debt-token units.
    uint256 public price = 60_000e6;

    /// @notice Base unit of the collateral token (e.g. 1e8 for BTC, 1e18 for ETH).
    uint256 public baseUnit = 1e8;

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function setBaseUnit(uint256 _baseUnit) external {
        baseUnit = _baseUnit;
    }

    function quote(uint256 collateralAmount) external view override returns (uint256) {
        return collateralAmount * price / baseUnit;
    }
}
