// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketAdapter} from "./IMarketAdapter.sol";
import {Auth} from "../utils/Auth.sol";

// -------- Morpho-specific interfaces (minimal) --------

/// @notice Minimal subset of the Morpho Blue singleton interface.
interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function supply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

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

    function supplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;

    function withdrawCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    function position(bytes32 id, address account) external view returns (Position memory);

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    function market(bytes32 id) external view returns (Market memory);
    function idToMarketParams(bytes32 id) external view returns (IMorpho.MarketParams memory);
}

/// @title MorphoAdapter
/// @notice Thin wrapper around a Morpho Blue market for any collateral/loan pair.
contract MorphoAdapter is IMarketAdapter, Auth {
    using SafeERC20 for IERC20;

    address public immutable morpho;
    address public immutable override collateralToken;
    address public immutable override loanToken;
    bytes32 public immutable marketId;

    IMorpho.MarketParams public marketParams;

    address public router;

    constructor(
        address _authority,
        address _morpho,
        address _collateralToken,
        address _loanToken,
        bytes32 _marketId,
        IMorpho.MarketParams memory _marketParams
    ) {
        authority = _authority;
        morpho = _morpho;
        collateralToken = _collateralToken;
        loanToken = _loanToken;
        marketId = _marketId;
        marketParams = _marketParams;

        IERC20(_collateralToken).forceApprove(_morpho, type(uint256).max);
        IERC20(_loanToken).forceApprove(_morpho, type(uint256).max);
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
        IMorpho(morpho).supplyCollateral(marketParams, shares, address(this), "");
    }

    /// @inheritdoc IMarketAdapter
    function withdrawCollateral(uint256 shares, address to) external override onlyRouter returns (uint256) {
        IMorpho(morpho).withdrawCollateral(marketParams, shares, address(this), to);
        return shares;
    }

    /// @inheritdoc IMarketAdapter
    function borrow(uint256 amount, address to) external override onlyRouter returns (uint256) {
        (uint256 borrowed,) = IMorpho(morpho).borrow(marketParams, amount, 0, address(this), to);
        return borrowed;
    }

    /// @inheritdoc IMarketAdapter
    function repay(uint256 amount) external override onlyRouter returns (uint256) {
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), amount);
        (uint256 repaid,) = IMorpho(morpho).repay(marketParams, amount, 0, address(this), "");
        return repaid;
    }

    // -------- IMarketAdapter views --------

    /// @inheritdoc IMarketAdapter
    function totalDebt() external view override returns (uint256) {
        IMorpho.Market memory m = IMorpho(morpho).market(marketId);
        IMorpho.Position memory p = IMorpho(morpho).position(marketId, address(this));
        if (m.totalBorrowShares == 0) return 0;
        return uint256(p.borrowShares) * uint256(m.totalBorrowAssets) / uint256(m.totalBorrowShares);
    }

    /// @inheritdoc IMarketAdapter
    function totalCollateralShares() external view override returns (uint256) {
        IMorpho.Position memory p = IMorpho(morpho).position(marketId, address(this));
        return uint256(p.collateral);
    }

    /// @inheritdoc IMarketAdapter
    function currentBorrowRate() external view override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IMarketAdapter
    function availableLiquidity() external view override returns (uint256) {
        IMorpho.Market memory m = IMorpho(morpho).market(marketId);
        uint256 totalSupply = uint256(m.totalSupplyAssets);
        uint256 totalBorrow = uint256(m.totalBorrowAssets);
        return totalSupply > totalBorrow ? totalSupply - totalBorrow : 0;
    }

    /// @inheritdoc IMarketAdapter
    function withdrawableCollateralShares() external view override returns (uint256) {
        IMorpho.Position memory p = IMorpho(morpho).position(marketId, address(this));
        return uint256(p.collateral);
    }
}
