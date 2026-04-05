// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYearnVault4626} from "../interfaces/IYearnVault4626.sol";
import {IYearnAuction} from "../interfaces/IYearnAuction.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AdapterRouter} from "./AdapterRouter.sol";
import {Auth} from "../utils/Auth.sol";

/// @title GemachPool
/// @notice Generic fixed-debt, reserve-backed, yield-subsidized borrowing pool.
///         Users deposit collateral, borrow debt tokens, and their debt stays
///         flat in normal mode. All yield is socialized to the protocol reserve.
contract GemachPool is Auth, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------- position --------

    struct Position {
        uint256 principal;   // exact collateral principal units owed back to user
        uint256 debtShares;  // user-facing debt shares
    }

    // -------- immutables --------

    address public immutable collateralToken; // e.g. cbBTC, WETH
    address public immutable debtToken;       // e.g. USDC, aUSD
    address public immutable yieldVault;      // ERC-4626 yield vault (e.g. yvBTC, yvETH)

    // -------- state --------

    mapping(address => Position) public positions;

    uint256 public totalPrincipal;
    uint256 public sponsorBackstop;

    uint256 public totalDebtShares;
    uint256 public debtIndex; // starts at 1e18, flat in normal mode

    bool public emergencyMode;
    bool public paused;

    address public router;
    address public oracle;

    address public yearnAuction;
    bytes32 public auctionId;
    address public feeRecipient;

    uint256 public maxBorrowLtvBps;
    uint256 public liquidationLtvBps;
    uint256 public liquidationBonusBps;

    uint256 public feeActivationBufferBps;
    uint256 public protocolFeeBps;
    uint256 public minAuctionLot;

    // -------- constructor --------

    constructor(
        address _authority,
        address _collateralToken,
        address _debtToken,
        address _yieldVault,
        address _router,
        address _oracle
    ) {
        authority = _authority;
        collateralToken = _collateralToken;
        debtToken = _debtToken;
        yieldVault = _yieldVault;
        router = _router;
        oracle = _oracle;
        debtIndex = 1e18;

        // pre-approve yield vault to pull collateral for deposits
        IERC20(_collateralToken).forceApprove(_yieldVault, type(uint256).max);
        // pre-approve router to pull yield-vault shares
        IERC20(_yieldVault).forceApprove(_router, type(uint256).max);
        // pre-approve router to pull debt tokens (for repayments)
        IERC20(_debtToken).forceApprove(_router, type(uint256).max);
    }

    // -------- modifiers --------

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    modifier whenNotEmergency() {
        require(!emergencyMode, "emergency mode");
        _;
    }

    // ================================================================
    //                        USER FLOWS
    // ================================================================

    /// @notice Deposit collateral.
    /// @param amount Amount of collateral token to deposit.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "zero amount");

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);

        // deposit collateral into yield vault -> receive vault shares
        uint256 vaultShares = IYearnVault4626(yieldVault).deposit(amount, address(this));

        // send vault shares to router as collateral
        AdapterRouter(router).supplyCollateralAuto(vaultShares);

        // update principal accounting
        positions[msg.sender].principal += amount;
        totalPrincipal += amount;
    }

    /// @notice Borrow debt tokens against deposited collateral.
    /// @param amount Amount of debt tokens to borrow.
    /// @param receiver Address to receive the borrowed tokens.
    function borrow(uint256 amount, address receiver) external nonReentrant whenNotPaused whenNotEmergency {
        require(amount > 0, "zero amount");

        // mint debt shares
        uint256 shares = amount * 1e18 / debtIndex;
        require(shares > 0, "shares zero");
        positions[msg.sender].debtShares += shares;
        totalDebtShares += shares;

        // check post-borrow LTV
        require(_userLtvBps(msg.sender) <= maxBorrowLtvBps, "ltv exceeded");

        // router borrows from lowest-cost adapter(s) and sends to receiver
        AdapterRouter(router).borrow(amount, receiver);
    }

    /// @notice Combined deposit + borrow convenience function.
    function depositAndBorrow(uint256 depositAmount, uint256 borrowAmount, address receiver) external nonReentrant whenNotPaused whenNotEmergency {
        // --- deposit ---
        require(depositAmount > 0, "zero deposit");
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), depositAmount);
        uint256 vaultShares = IYearnVault4626(yieldVault).deposit(depositAmount, address(this));
        AdapterRouter(router).supplyCollateralAuto(vaultShares);
        positions[msg.sender].principal += depositAmount;
        totalPrincipal += depositAmount;

        // --- borrow ---
        require(borrowAmount > 0, "zero borrow");
        uint256 shares = borrowAmount * 1e18 / debtIndex;
        require(shares > 0, "shares zero");
        positions[msg.sender].debtShares += shares;
        totalDebtShares += shares;
        require(_userLtvBps(msg.sender) <= maxBorrowLtvBps, "ltv exceeded");
        AdapterRouter(router).borrow(borrowAmount, receiver);
    }

    /// @notice Repay debt.
    /// @param amount Amount of debt tokens to repay.
    function repay(uint256 amount) external nonReentrant {
        _repayFor(msg.sender, amount);
    }

    /// @notice Repay debt on behalf of another user.
    function repayFor(address user, uint256 amount) external nonReentrant {
        _repayFor(user, amount);
    }

    /// @notice Withdraw collateral.
    /// @param amount Amount of collateral to withdraw.
    /// @param receiver Address to receive the collateral.
    function withdraw(uint256 amount, address receiver) external nonReentrant whenNotPaused {
        require(amount > 0, "zero amount");
        Position storage pos = positions[msg.sender];
        require(pos.principal >= amount, "insufficient principal");

        // decrement principal
        pos.principal -= amount;
        totalPrincipal -= amount;

        // check post-withdraw LTV (only if user still has debt)
        if (pos.debtShares > 0) {
            require(_userLtvBps(msg.sender) <= maxBorrowLtvBps, "ltv exceeded");
        }

        // pull vault shares from router and redeem exact collateral
        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        IYearnVault4626(yieldVault).withdraw(amount, receiver, address(this));
    }

    // ================================================================
    //                        LIQUIDATION
    // ================================================================

    /// @notice Liquidate an unhealthy position.
    /// @param user The borrower to liquidate.
    /// @param repayAmount Amount of debt tokens the liquidator is repaying.
    /// @param receiveCollateral If true, liquidator receives base collateral; otherwise vault shares.
    /// @param receiver Address to receive the seized collateral.
    function liquidate(
        address user,
        uint256 repayAmount,
        bool receiveCollateral,
        address receiver
    ) external nonReentrant {
        require(repayAmount > 0, "zero repay");
        require(_userLtvBps(user) > liquidationLtvBps, "not liquidatable");

        Position storage pos = positions[user];
        uint256 currentDebt = pos.debtShares * debtIndex / 1e18;
        // cap repay to user's total debt
        if (repayAmount > currentDebt) repayAmount = currentDebt;

        // pull debt tokens from liquidator
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), repayAmount);

        // route repayment to highest-cost adapter(s)
        AdapterRouter(router).repay(repayAmount);

        // burn user debt shares
        uint256 sharesBurned = repayAmount * 1e18 / debtIndex;
        pos.debtShares -= sharesBurned;
        totalDebtShares -= sharesBurned;

        // compute seized collateral principal (repay value + bonus)
        uint256 seizedValue = repayAmount * (10000 + liquidationBonusBps) / 10000;
        uint256 seizedCollateral = _debtToCollateral(seizedValue);
        // cap to user's remaining principal
        if (seizedCollateral > pos.principal) seizedCollateral = pos.principal;

        // decrement principal
        pos.principal -= seizedCollateral;
        totalPrincipal -= seizedCollateral;

        // pull vault shares from router
        uint256 sharesNeeded = _ceilConvertToShares(seizedCollateral);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));

        if (receiveCollateral) {
            IYearnVault4626(yieldVault).withdraw(seizedCollateral, receiver, address(this));
        } else {
            IERC20(yieldVault).safeTransfer(receiver, sharesNeeded);
        }
    }

    // ================================================================
    //                     AUCTION INTEGRATION
    // ================================================================

    /// @notice Push harvestable surplus to the auction contract.
    /// @param maxAmount Maximum collateral to push.
    function pushSurplusToAuction(uint256 maxAmount) external nonReentrant onlyKeeper {
        uint256 surplus = harvestableSurplus();
        require(surplus > 0, "no surplus");

        uint256 amount = maxAmount > surplus ? surplus : maxAmount;
        require(amount >= minAuctionLot, "below min lot");

        // pull vault shares from router
        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));

        // redeem to base collateral
        uint256 redeemed = IYearnVault4626(yieldVault).redeem(
            IERC20(yieldVault).balanceOf(address(this)),
            address(this),
            address(this)
        );

        // send collateral to auction
        IERC20(collateralToken).safeTransfer(yearnAuction, redeemed);
    }

    /// @notice Sell protocol sponsor backstop via auction.
    /// @param maxAmount Maximum collateral to sell from backstop.
    function sellBackstopToAuction(uint256 maxAmount) external nonReentrant onlyKeeper {
        require(sponsorBackstop > 0, "no backstop");

        uint256 amount = maxAmount > sponsorBackstop ? sponsorBackstop : maxAmount;
        require(amount >= minAuctionLot, "below min lot");

        sponsorBackstop -= amount;

        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));

        uint256 redeemed = IYearnVault4626(yieldVault).redeem(
            IERC20(yieldVault).balanceOf(address(this)),
            address(this),
            address(this)
        );

        IERC20(collateralToken).safeTransfer(yearnAuction, redeemed);
    }

    /// @notice Kick the configured auction.
    function kickAuction() external onlyKeeper {
        require(yearnAuction != address(0), "no auction");
        IYearnAuction(yearnAuction).kick(auctionId);
    }

    /// @notice Route idle debt tokens in the pool to repay highest-cost adapter(s).
    /// @param maxAmount Maximum debt tokens to deploy.
    function routeIdleDebtTokens(uint256 maxAmount) external nonReentrant onlyKeeper {
        uint256 idle = IERC20(debtToken).balanceOf(address(this));
        require(idle > 0, "no idle debt tokens");

        uint256 amount = maxAmount > idle ? idle : maxAmount;
        AdapterRouter(router).repay(amount);
    }

    // ================================================================
    //                   BUFFER / FEES / BACKSTOP
    // ================================================================

    /// @notice Current idle debt-token buffer balance.
    function bufferBalance() public view returns (uint256) {
        return IERC20(debtToken).balanceOf(address(this));
    }

    /// @notice Deposit debt tokens directly into the buffer. Keeper / governance.
    function depositBuffer(uint256 amount) external nonReentrant onlyKeeper {
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Deposit sponsor backstop in collateral token.
    function depositBackstop(uint256 amount) external nonReentrant onlyKeeper {
        require(amount > 0, "zero amount");
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 vaultShares = IYearnVault4626(yieldVault).deposit(amount, address(this));
        AdapterRouter(router).supplyCollateralAuto(vaultShares);
        sponsorBackstop += amount;
    }

    /// @notice Withdraw sponsor backstop. Governance only, with safety checks.
    function withdrawBackstop(uint256 amount, address receiver) external nonReentrant onlyGovernance whenNotPaused whenNotEmergency {
        require(amount > 0, "zero amount");
        require(sponsorBackstop >= amount, "insufficient backstop");
        require(carryGap() == 0, "carry gap exists");

        sponsorBackstop -= amount;

        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        IYearnVault4626(yieldVault).withdraw(amount, receiver, address(this));
    }

    /// @notice Take protocol fee from buffer excess. Governance only.
    function takeProtocolFee(uint256 amount) external nonReentrant onlyGovernance whenNotPaused whenNotEmergency {
        require(feeRecipient != address(0), "no fee recipient");
        require(carryGap() == 0, "carry gap exists");

        uint256 target = totalUserDebt() * feeActivationBufferBps / 10000;
        uint256 buffer = bufferBalance();
        require(buffer > target, "buffer below target");
        uint256 excess = buffer - target;
        uint256 maxFee = excess * protocolFeeBps / 10000;
        require(amount <= maxFee, "exceeds fee cap");

        IERC20(debtToken).safeTransfer(feeRecipient, amount);
    }

    // ================================================================
    //                      EMERGENCY MODE
    // ================================================================

    /// @notice Sync state and enter emergency mode if conditions are met.
    function syncAndMaybeEnterEmergency() external onlyKeeper {
        if (emergencyMode) return;
        uint256 buffer = bufferBalance();
        uint256 extDebt = AdapterRouter(router).totalDebt();
        uint256 uDebt = totalUserDebt();
        if (buffer == 0 && sponsorBackstop == 0 && extDebt > uDebt) {
            emergencyMode = true;
        }
    }

    /// @notice Force emergency mode. Governance only.
    function forceEmergencyMode() external onlyGovernance {
        emergencyMode = true;
    }

    /// @notice Clear emergency mode once healthy. Governance only.
    function clearEmergencyMode() external onlyGovernance {
        require(emergencyMode, "not in emergency");
        uint256 extDebt = AdapterRouter(router).totalDebt();
        uint256 uDebt = totalUserDebt();
        require(extDebt <= uDebt, "carry gap remains");
        emergencyMode = false;
    }

    /// @notice Capitalize uncovered shortfall onto borrowers in emergency mode.
    ///         Increases debtIndex so user debt rises pro-rata.
    function capitalizeEmergencyShortfall() external nonReentrant onlyKeeper {
        require(emergencyMode, "not emergency");
        require(totalDebtShares > 0, "no debt shares");

        uint256 extDebt = AdapterRouter(router).totalDebt();
        uint256 uDebt = totalUserDebt();
        require(extDebt > uDebt, "no shortfall");

        uint256 shortfall = extDebt - uDebt;
        debtIndex += shortfall * 1e18 / totalDebtShares;
    }

    // ================================================================
    //                      PAUSE / ADMIN
    // ================================================================

    /// @notice Pause the pool. Guardian or governance.
    function pause() external onlyGuardian {
        paused = true;
    }

    /// @notice Unpause the pool. Governance only.
    function unpause() external onlyGovernance {
        paused = false;
    }

    // --- governance setters ---

    /// @notice Set the price oracle address.
    function setOracle(address _oracle) external onlyGovernance {
        require(_oracle != address(0), "zero address");
        oracle = _oracle;
    }

    /// @notice Set the adapter router address.
    function setRouter(address _router) external onlyGovernance {
        require(_router != address(0), "zero address");
        router = _router;
        IERC20(yieldVault).forceApprove(_router, type(uint256).max);
        IERC20(debtToken).forceApprove(_router, type(uint256).max);
    }

    /// @notice Set the auction address and auction id.
    function setAuction(address _auction, bytes32 _auctionId) external onlyGovernance {
        yearnAuction = _auction;
        auctionId = _auctionId;
    }

    /// @notice Set the fee recipient.
    function setFeeRecipient(address _recipient) external onlyGovernance {
        feeRecipient = _recipient;
    }

    /// @notice Set max borrow LTV in basis points.
    function setMaxBorrowLtvBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 9500, "too high");
        maxBorrowLtvBps = _bps;
    }

    /// @notice Set liquidation LTV threshold in basis points.
    function setLiquidationLtvBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 9900, "too high");
        liquidationLtvBps = _bps;
    }

    /// @notice Set liquidation bonus in basis points.
    function setLiquidationBonusBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 2000, "too high");
        liquidationBonusBps = _bps;
    }

    /// @notice Set fee activation buffer threshold in basis points.
    function setFeeActivationBufferBps(uint256 _bps) external onlyGovernance {
        feeActivationBufferBps = _bps;
    }

    /// @notice Set protocol fee in basis points.
    function setProtocolFeeBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 5000, "too high");
        protocolFeeBps = _bps;
    }

    /// @notice Set minimum auction lot size.
    function setMinAuctionLot(uint256 _min) external onlyGovernance {
        minAuctionLot = _min;
    }

    /// @notice Set the authority address (migrate to new authority).
    function setAuthority(address _authority) external onlyGovernance {
        require(_authority != address(0), "zero address");
        authority = _authority;
    }

    // --- governance emergency tools ---

    /// @notice Repay a specific adapter directly using pool debt tokens. Governance only.
    function manualRepayAdapter(address adapter, uint256 amount) external nonReentrant onlyGovernance {
        AdapterRouter(router).repayAdapter(adapter, amount);
    }

    /// @notice Delever using idle debt tokens, repaying external debt. Governance only.
    function manualDelever(uint256 amount) external nonReentrant onlyGovernance {
        uint256 idle = bufferBalance();
        require(amount <= idle, "insufficient buffer");
        AdapterRouter(router).repay(amount);
    }

    /// @notice Sweep a non-core token accidentally sent to the pool.
    function sweepNonCoreToken(address token, address to, uint256 amount) external onlyGovernance {
        require(token != collateralToken, "cannot sweep collateral");
        require(token != debtToken, "cannot sweep debt token");
        require(token != yieldVault, "cannot sweep yield vault");
        IERC20(token).safeTransfer(to, amount);
    }

    // ================================================================
    //                       VIEW HELPERS
    // ================================================================

    /// @notice User debt in debt-token units.
    function userDebt(address user) public view returns (uint256) {
        return positions[user].debtShares * debtIndex / 1e18;
    }

    /// @notice Total user debt across all borrowers.
    function totalUserDebt() public view returns (uint256) {
        return totalDebtShares * debtIndex / 1e18;
    }

    /// @notice Total yield-vault shares owned by the system (pool idle + router).
    function totalVaultShares() public view returns (uint256) {
        return IERC20(yieldVault).balanceOf(address(this)) + AdapterRouter(router).totalCollateralShares();
    }

    /// @notice Total underlying collateral represented by all vault shares.
    function totalUnderlying() public view returns (uint256) {
        return IYearnVault4626(yieldVault).convertToAssets(totalVaultShares());
    }

    /// @notice Collateral required to fully back user principal + sponsor backstop.
    function requiredBacking() public view returns (uint256) {
        return totalPrincipal + sponsorBackstop;
    }

    /// @notice Harvestable yield surplus above required backing.
    function harvestableSurplus() public view returns (uint256) {
        uint256 underlying = totalUnderlying();
        uint256 required = requiredBacking();
        return underlying > required ? underlying - required : 0;
    }

    /// @notice External (adapter) debt.
    function externalDebt() public view returns (uint256) {
        return AdapterRouter(router).totalDebt();
    }

    /// @notice Carry gap = external debt above total user debt.
    function carryGap() public view returns (uint256) {
        uint256 extDebt = externalDebt();
        uint256 uDebt = totalUserDebt();
        return extDebt > uDebt ? extDebt - uDebt : 0;
    }

    /// @notice User collateral value in debt-token units.
    function userCollateralValue(address user) public view returns (uint256) {
        return IPriceOracle(oracle).quote(positions[user].principal);
    }

    // ================================================================
    //                       INTERNAL
    // ================================================================

    function _repayFor(address user, uint256 amount) internal {
        require(amount > 0, "zero amount");

        Position storage pos = positions[user];
        uint256 currentDebt = pos.debtShares * debtIndex / 1e18;
        if (amount > currentDebt) amount = currentDebt;

        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), amount);

        AdapterRouter(router).repay(amount);

        uint256 sharesBurned = amount * 1e18 / debtIndex;
        pos.debtShares -= sharesBurned;
        totalDebtShares -= sharesBurned;
    }

    /// @notice User LTV in basis points.
    function _userLtvBps(address user) internal view returns (uint256) {
        Position storage pos = positions[user];
        if (pos.principal == 0) return type(uint256).max;
        uint256 debt = pos.debtShares * debtIndex / 1e18;
        if (debt == 0) return 0;
        uint256 colValue = IPriceOracle(oracle).quote(pos.principal);
        require(colValue > 0, "oracle: zero value");
        return debt * 10000 / colValue;
    }

    /// @notice Convert debt-token value to collateral amount via oracle.
    function _debtToCollateral(uint256 debtValue) internal view returns (uint256) {
        uint256 oneUnit = 10 ** _collateralDecimals();
        uint256 pricePerUnit = IPriceOracle(oracle).quote(oneUnit);
        require(pricePerUnit > 0, "oracle: zero price");
        return debtValue * oneUnit / pricePerUnit;
    }

    /// @notice Ceiling division for convertToShares.
    function _ceilConvertToShares(uint256 assets) internal view returns (uint256) {
        uint256 shares = IYearnVault4626(yieldVault).convertToShares(assets);
        if (IYearnVault4626(yieldVault).convertToAssets(shares) < assets) {
            shares += 1;
        }
        return shares;
    }

    /// @notice Returns the decimals of the collateral token. Cached-friendly
    ///         helper for _debtToCollateral pricing math.
    function _collateralDecimals() internal view returns (uint8) {
        // ERC-20 optional decimals(); fall back to 18 if missing
        (bool ok, bytes memory ret) = collateralToken.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (ok && ret.length >= 32) {
            return abi.decode(ret, (uint8));
        }
        return 18;
    }
}
