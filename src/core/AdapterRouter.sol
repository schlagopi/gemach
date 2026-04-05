// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketAdapter} from "../adapters/IMarketAdapter.sol";
import {Auth} from "../utils/Auth.sol";

/// @title AdapterRouter
/// @notice Small router over approved lending adapters. Borrows from the
///         preferred adapter first (governance-set order); repays in reverse
///         order. No on-chain rate queries — management sets the priority.
contract AdapterRouter is Auth {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_ADAPTERS = 8;

    address public immutable COLLATERAL_TOKEN; // yield vault share token
    address public immutable DEBT_TOKEN;

    address public pool;

    /// @notice Ordered adapter list. Index 0 is the preferred borrow target;
    ///         last index is the preferred repay target. Governance controls
    ///         ordering via addAdapter / reorderAdapters.
    address[] public adapters;
    mapping(address => bool) public adapterEnabled;

    constructor(address _authority, address _collateralToken, address _debtToken) {
        authority = _authority;
        COLLATERAL_TOKEN = _collateralToken;
        DEBT_TOKEN = _debtToken;
    }

    modifier onlyPool() {
        require(msg.sender == pool, "not pool");
        _;
    }

    // -------- governance config --------

    function setPool(address _pool) external onlyGovernance {
        pool = _pool;
    }

    function addAdapter(address adapter) external onlyGovernance {
        require(!adapterEnabled[adapter], "already enabled");
        require(adapters.length < MAX_ADAPTERS, "max adapters");
        require(IMarketAdapter(adapter).collateralToken() == COLLATERAL_TOKEN, "wrong collateral");
        require(IMarketAdapter(adapter).loanToken() == DEBT_TOKEN, "wrong loan");
        adapters.push(adapter);
        adapterEnabled[adapter] = true;
        IERC20(COLLATERAL_TOKEN).forceApprove(adapter, type(uint256).max);
        IERC20(DEBT_TOKEN).forceApprove(adapter, type(uint256).max);
    }

    function disableAdapter(address adapter) external onlyGovernance {
        require(adapterEnabled[adapter], "not enabled");
        adapterEnabled[adapter] = false;
    }

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

    /// @notice Reorder adapters. Index 0 = preferred for borrows,
    ///         last index = preferred for repays. All current adapters
    ///         must appear exactly once.
    function reorderAdapters(address[] calldata _newOrder) external onlyGovernance {
        require(_newOrder.length == adapters.length, "length mismatch");
        // verify same set
        for (uint256 i = 0; i < _newOrder.length; i++) {
            bool found;
            for (uint256 j = 0; j < adapters.length; j++) {
                if (_newOrder[i] == adapters[j]) found = true;
                break;
            }
            require(found, "unknown adapter");
        }
        adapters = _newOrder;
    }

    // -------- pool-callable routing --------

    function supplyCollateral(address adapter, uint256 shares) external onlyPool {
        require(adapterEnabled[adapter], "adapter not enabled");
        IERC20(COLLATERAL_TOKEN).safeTransferFrom(msg.sender, address(this), shares);
        IMarketAdapter(adapter).supplyCollateral(shares);
    }

    function supplyCollateralAuto(uint256 shares) external onlyPool {
        address adapter = _firstEnabled();
        IERC20(COLLATERAL_TOKEN).safeTransferFrom(msg.sender, address(this), shares);
        IMarketAdapter(adapter).supplyCollateral(shares);
    }

    /// @notice Borrow debt tokens. Tries adapters in order (index 0 first).
    function borrow(uint256 amount, address to) external onlyPool returns (uint256 borrowed) {
        uint256 remaining = amount;
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len && remaining > 0; i++) {
            address a = adapters[i];
            if (!adapterEnabled[a]) continue;
            uint256 liq = IMarketAdapter(a).availableLiquidity();
            if (liq == 0) continue;
            uint256 chunk = remaining > liq ? liq : remaining;
            uint256 got = IMarketAdapter(a).borrow(chunk, to);
            borrowed += got;
            remaining -= got;
        }
        require(remaining == 0, "no liquidity");
    }

    /// @notice Repay debt tokens. Tries adapters in reverse order (last index first).
    function repay(uint256 amount) external onlyPool returns (uint256 repaid) {
        IERC20(DEBT_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        uint256 remaining = amount;
        uint256 len = adapters.length;
        for (uint256 i = len; i > 0 && remaining > 0; i--) {
            address a = adapters[i - 1];
            uint256 debt = IMarketAdapter(a).totalDebt();
            if (debt == 0) continue;
            uint256 chunk = remaining > debt ? debt : remaining;
            uint256 paid = IMarketAdapter(a).repay(chunk);
            repaid += paid;
            remaining -= paid;
        }
        if (remaining > 0) {
            IERC20(DEBT_TOKEN).safeTransfer(msg.sender, remaining);
        }
    }

    function repayAdapter(address adapter, uint256 amount) external onlyPool returns (uint256) {
        IERC20(DEBT_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        return IMarketAdapter(adapter).repay(amount);
    }

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

    function totalDebt() external view returns (uint256 total) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IMarketAdapter(adapters[i]).totalDebt();
        }
    }

    function totalCollateralShares() external view returns (uint256 total) {
        uint256 len = adapters.length;
        for (uint256 i = 0; i < len; i++) {
            total += IMarketAdapter(adapters[i]).totalCollateralShares();
        }
    }

    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

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
