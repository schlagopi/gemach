// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketAdapter} from "../adapters/IMarketAdapter.sol";
import {Auth} from "../utils/Auth.sol";

/// @title AdapterRouter
/// @notice Small router over approved lending adapters. Routes borrows to the
///         lowest-cost adapter and repayments to the highest-cost adapter.
///         Maintains a bounded set of enabled adapters (max 8).
contract AdapterRouter is Auth {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_ADAPTERS = 8;

    address public immutable collateralToken; // yield vault share token
    address public immutable debtToken;

    address public pool; // only the pool may call mutative routing functions

    address[] public adapters;
    mapping(address => bool) public adapterEnabled;

    constructor(address _authority, address _collateralToken, address _debtToken) {
        authority = _authority;
        collateralToken = _collateralToken;
        debtToken = _debtToken;
    }

    modifier onlyPool() {
        require(msg.sender == pool, "not pool");
        _;
    }

    // -------- governance config --------

    /// @notice Set the authorized pool. Governance only.
    function setPool(address _pool) external onlyGovernance {
        pool = _pool;
    }

    /// @notice Add an adapter. Governance only.
    function addAdapter(address adapter) external onlyGovernance {
        require(!adapterEnabled[adapter], "already enabled");
        require(adapters.length < MAX_ADAPTERS, "max adapters");
        require(IMarketAdapter(adapter).collateralToken() == collateralToken, "wrong collateral");
        require(IMarketAdapter(adapter).loanToken() == debtToken, "wrong loan");
        adapters.push(adapter);
        adapterEnabled[adapter] = true;

        IERC20(collateralToken).forceApprove(adapter, type(uint256).max);
        IERC20(debtToken).forceApprove(adapter, type(uint256).max);
    }

    /// @notice Disable an adapter (stops new borrows, still repayable). Governance only.
    function disableAdapter(address adapter) external onlyGovernance {
        require(adapterEnabled[adapter], "not enabled");
        adapterEnabled[adapter] = false;
    }

    /// @notice Remove a fully-drained adapter from the list. Governance only.
    function removeAdapter(address adapter) external onlyGovernance {
        require(!adapterEnabled[adapter], "still enabled");
        require(IMarketAdapter(adapter).totalDebt() == 0, "has debt");
        require(IMarketAdapter(adapter).totalCollateralShares() == 0, "has collateral");

        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (adapters[i] == adapter) {
                adapters[i] = adapters[len - 1];
                adapters.pop();
                break;
            }
        }
    }

    // -------- pool-callable routing --------

    /// @notice Supply collateral to the given adapter.
    function supplyCollateral(address adapter, uint256 shares) external onlyPool {
        require(adapterEnabled[adapter], "adapter not enabled");
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), shares);
        IMarketAdapter(adapter).supplyCollateral(shares);
    }

    /// @notice Supply collateral, auto-selecting the first enabled adapter.
    function supplyCollateralAuto(uint256 shares) external onlyPool {
        address adapter = _firstEnabled();
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), shares);
        IMarketAdapter(adapter).supplyCollateral(shares);
    }

    /// @notice Borrow debt tokens, routing to the lowest-cost enabled adapter(s).
    /// @return borrowed Total debt tokens actually borrowed.
    function borrow(uint256 amount, address to) external onlyPool returns (uint256 borrowed) {
        uint256 remaining = amount;
        uint256 len = adapters.length;

        while (remaining > 0) {
            address best;
            uint256 bestRate = type(uint256).max;

            for (uint256 i = 0; i < len; i++) {
                address a = adapters[i];
                if (!adapterEnabled[a]) continue;
                uint256 adapterLiq = IMarketAdapter(a).availableLiquidity();
                if (adapterLiq == 0) continue;
                uint256 rate = IMarketAdapter(a).currentBorrowRate();
                if (rate < bestRate) {
                    bestRate = rate;
                    best = a;
                }
            }
            require(best != address(0), "no liquidity");

            uint256 liq = IMarketAdapter(best).availableLiquidity();
            uint256 chunk = remaining > liq ? liq : remaining;
            uint256 got = IMarketAdapter(best).borrow(chunk, to);
            borrowed += got;
            remaining -= got;
        }
    }

    /// @notice Repay debt tokens, routing to the highest-cost adapter(s).
    /// @return repaid Total debt tokens actually repaid.
    function repay(uint256 amount) external onlyPool returns (uint256 repaid) {
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 remaining = amount;
        uint256 len = adapters.length;

        while (remaining > 0) {
            address best;
            uint256 bestRate = 0;
            bool found;

            for (uint256 i = 0; i < len; i++) {
                address a = adapters[i];
                uint256 adapterDebt = IMarketAdapter(a).totalDebt();
                if (adapterDebt == 0) continue;
                uint256 rate = IMarketAdapter(a).currentBorrowRate();
                if (!found || rate > bestRate) {
                    bestRate = rate;
                    best = a;
                    found = true;
                }
            }
            if (!found) break;

            uint256 debt = IMarketAdapter(best).totalDebt();
            uint256 chunk = remaining > debt ? debt : remaining;
            uint256 paid = IMarketAdapter(best).repay(chunk);
            repaid += paid;
            remaining -= paid;
        }

        // return any excess to the pool
        if (remaining > 0) {
            IERC20(debtToken).safeTransfer(msg.sender, remaining);
        }
    }

    /// @notice Repay a specific adapter directly. Pool only.
    function repayAdapter(address adapter, uint256 amount) external onlyPool returns (uint256) {
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), amount);
        return IMarketAdapter(adapter).repay(amount);
    }

    /// @notice Withdraw collateral shares from adapters.
    /// @return withdrawn Total collateral shares actually withdrawn.
    function withdrawCollateralShares(uint256 shares, address to) external onlyPool returns (uint256 withdrawn) {
        uint256 remaining = shares;
        uint256 len = adapters.length;

        for (uint256 i = 0; i < len && remaining > 0; i++) {
            address a = adapters[i];
            uint256 available = IMarketAdapter(a).withdrawableCollateralShares();
            if (available == 0) continue;
            uint256 chunk = remaining > available ? available : remaining;
            uint256 got = IMarketAdapter(a).withdrawCollateral(chunk, to);
            withdrawn += got;
            remaining -= got;
        }
        require(remaining == 0, "insufficient withdrawable collateral");
    }

    // -------- aggregate views --------

    /// @notice Total debt across all adapters.
    function totalDebt() external view returns (uint256 total) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IMarketAdapter(adapters[i]).totalDebt();
        }
    }

    /// @notice Total collateral shares across all adapters.
    function totalCollateralShares() external view returns (uint256 total) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IMarketAdapter(adapters[i]).totalCollateralShares();
        }
    }

    /// @notice Number of registered adapters.
    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

    /// @notice Return the full adapter list.
    function getAdapters() external view returns (address[] memory) {
        return adapters;
    }

    // -------- internal --------

    function _firstEnabled() internal view returns (address) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (adapterEnabled[adapters[i]]) return adapters[i];
        }
        revert("no enabled adapter");
    }
}
