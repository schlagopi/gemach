// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMorpho
/// @notice Minimal subset of the Morpho Blue singleton interface.
interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    function supplyCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external;

    function withdrawCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, address receiver)
        external;

    function borrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function repay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    function position(bytes32 id, address account) external view returns (Position memory);
    function market(bytes32 id) external view returns (Market memory);
}
