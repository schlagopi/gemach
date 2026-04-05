// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IYearnVault4626} from "../interfaces/IYearnVault4626.sol";
import {IYearnAuction} from "../interfaces/IYearnAuction.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AdapterRouter} from "./AdapterRouter.sol";
import {Auth} from "../utils/Auth.sol";

/// @title GemachPool
/// @notice Generic fixed-debt, reserve-backed, yield-subsidized borrowing pool.
///         Users deposit collateral, borrow debt tokens, and their debt stays
///         flat in normal mode. All yield is socialized to the protocol reserve.
///         The buffer is virtual: totalUserDebt - externalDebt. All debt-token
///         proceeds are used to repay adapters; fee extraction borrows from them.
contract GemachPool is Auth, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------- position --------

    struct Position {
        uint256 principal; // exact collateral principal units owed back to user
        uint256 debtShares; // user-facing debt shares
    }

    // -------- immutables --------

    address public immutable COLLATERAL_TOKEN;
    address public immutable DEBT_TOKEN;
    address public immutable YIELD_VAULT;
    uint8 public immutable COLLATERAL_DECIMALS;
    uint8 public immutable DEBT_DECIMALS;

    // -------- state --------

    mapping(address => Position) public positions;
    mapping(address => mapping(address => bool)) public operators;

    uint256 public totalPrincipal;
    uint256 public sponsorBackstop;

    uint256 public totalDebtShares;
    uint256 public debtIndex; // starts at 1e18, flat in normal mode

    bool public emergencyMode;
    bool public paused;

    address public router;
    address public oracle;

    address public yearnAuction;
    address public feeRecipient;

    uint256 public maxBorrowLtvBps;
    uint256 public liquidationLtvBps;
    uint256 public liquidationBonusBps;

    uint256 public feeActivationBufferBps;
    uint256 public protocolFeeBps;
    uint256 public minAuctionLot;

    uint256 public auctionStartingPriceBps;
    uint256 public auctionSlippageBps;
    uint256 public auctionDecayRate;

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
        COLLATERAL_TOKEN = _collateralToken;
        DEBT_TOKEN = _debtToken;
        YIELD_VAULT = _yieldVault;
        COLLATERAL_DECIMALS = IERC20Metadata(_collateralToken).decimals();
        DEBT_DECIMALS = IERC20Metadata(_debtToken).decimals();
        router = _router;
        oracle = _oracle;
        debtIndex = 1e18;

        auctionStartingPriceBps = 10050;
        auctionSlippageBps = 50;
        auctionDecayRate = 50;

        IERC20(_collateralToken).forceApprove(_yieldVault, type(uint256).max);
        IERC20(_yieldVault).forceApprove(_router, type(uint256).max);
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
    //                         OPERATORS
    // ================================================================

    /// @notice Approve or revoke an operator who can borrow/withdraw on your behalf.
    function setOperator(address operator, bool approved) external {
        operators[msg.sender][operator] = approved;
    }

    function _checkAuthorized(address user) internal view {
        require(msg.sender == user || operators[user][msg.sender], "not authorized");
    }

    // ================================================================
    //                        USER FLOWS
    // ================================================================

    /// @notice Deposit collateral for yourself.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        _deposit(msg.sender, amount);
    }

    /// @notice Deposit collateral on behalf of another user.
    function depositFor(address onBehalfOf, uint256 amount) external nonReentrant whenNotPaused {
        _deposit(onBehalfOf, amount);
    }

    /// @notice Borrow debt tokens against your collateral.
    function borrow(uint256 amount, address receiver) external nonReentrant whenNotPaused whenNotEmergency {
        _borrow(msg.sender, amount, receiver);
    }

    /// @notice Borrow from another user's position (requires operator approval).
    function borrowFrom(address user, uint256 amount, address receiver)
        external
        nonReentrant
        whenNotPaused
        whenNotEmergency
    {
        _checkAuthorized(user);
        _borrow(user, amount, receiver);
    }

    /// @notice Combined deposit + borrow for yourself.
    function depositAndBorrow(uint256 depositAmount, uint256 borrowAmount, address receiver)
        external
        nonReentrant
        whenNotPaused
        whenNotEmergency
    {
        _deposit(msg.sender, depositAmount);
        _borrow(msg.sender, borrowAmount, receiver);
    }

    /// @notice Repay your own debt.
    function repay(uint256 amount) external nonReentrant {
        _repayFor(msg.sender, amount);
    }

    /// @notice Repay debt on behalf of another user (always permitted).
    function repayFor(address user, uint256 amount) external nonReentrant {
        _repayFor(user, amount);
    }

    /// @notice Withdraw your own collateral.
    function withdraw(uint256 amount, address receiver) external nonReentrant whenNotPaused {
        _withdraw(msg.sender, amount, receiver);
    }

    /// @notice Withdraw from another user's position (requires operator approval).
    function withdrawFrom(address user, uint256 amount, address receiver) external nonReentrant whenNotPaused {
        _checkAuthorized(user);
        _withdraw(user, amount, receiver);
    }

    // ================================================================
    //                        LIQUIDATION
    // ================================================================

    /// @notice Liquidate an unhealthy position.
    function liquidate(address user, uint256 repayAmount, bool receiveCollateral, address receiver)
        external
        nonReentrant
    {
        require(repayAmount > 0, "zero repay");
        require(_userLtvBps(user) > liquidationLtvBps, "not liquidatable");

        Position storage pos = positions[user];
        uint256 currentDebt = pos.debtShares * debtIndex / 1e18;
        if (repayAmount > currentDebt) repayAmount = currentDebt;

        IERC20(DEBT_TOKEN).safeTransferFrom(msg.sender, address(this), repayAmount);
        AdapterRouter(router).repay(repayAmount);

        uint256 sharesBurned = repayAmount * 1e18 / debtIndex;
        pos.debtShares -= sharesBurned;
        totalDebtShares -= sharesBurned;

        uint256 seizedValue = repayAmount * (10000 + liquidationBonusBps) / 10000;
        uint256 seizedCollateral = _debtToCollateral(seizedValue);
        if (seizedCollateral > pos.principal) seizedCollateral = pos.principal;

        pos.principal -= seizedCollateral;
        totalPrincipal -= seizedCollateral;

        uint256 sharesNeeded = _ceilConvertToShares(seizedCollateral);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));

        if (receiveCollateral) {
            IYearnVault4626(YIELD_VAULT).withdraw(seizedCollateral, receiver, address(this));
        } else {
            IERC20(YIELD_VAULT).safeTransfer(receiver, sharesNeeded);
        }
    }

    // ================================================================
    //              YEARN AUCTION v1.0.4 INTEGRATION
    // ================================================================

    /// @notice Push harvestable surplus to the Yearn auction and kick it.
    function pushSurplusToAuction(uint256 maxAmount) external nonReentrant onlyKeeper {
        require(yearnAuction != address(0), "no auction");
        uint256 surplus = harvestableSurplus();
        require(surplus > 0, "no surplus");

        uint256 amount = maxAmount > surplus ? surplus : maxAmount;
        require(amount >= minAuctionLot, "below min lot");

        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        uint256 redeemed = IYearnVault4626(YIELD_VAULT)
            .redeem(IERC20(YIELD_VAULT).balanceOf(address(this)), address(this), address(this));

        _configureAndKickAuction(redeemed);
    }

    /// @notice Sell protocol sponsor backstop via Yearn auction.
    function sellBackstopToAuction(uint256 maxAmount) external nonReentrant onlyKeeper {
        require(yearnAuction != address(0), "no auction");
        require(sponsorBackstop > 0, "no backstop");

        uint256 amount = maxAmount > sponsorBackstop ? sponsorBackstop : maxAmount;
        require(amount >= minAuctionLot, "below min lot");
        sponsorBackstop -= amount;

        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        uint256 redeemed = IYearnVault4626(YIELD_VAULT)
            .redeem(IERC20(YIELD_VAULT).balanceOf(address(this)), address(this), address(this));

        _configureAndKickAuction(redeemed);
    }

    /// @notice Kick an auction for collateral already in the auction contract.
    function kickAuction() external onlyKeeper {
        require(yearnAuction != address(0), "no auction");
        IYearnAuction auction_ = IYearnAuction(yearnAuction);
        require(!auction_.isActive(COLLATERAL_TOKEN), "auction active");
        uint256 kickableAmt = auction_.kickable(COLLATERAL_TOKEN);
        require(kickableAmt > 0, "nothing to kick");
        _setAuctionPricing(kickableAmt);
        auction_.kick(COLLATERAL_TOKEN);
    }

    /// @notice Route idle debt tokens sitting in the pool to repay adapters.
    ///         This grows the virtual protocol buffer.
    function routeIdleDebtTokens(uint256 maxAmount) external nonReentrant onlyKeeper {
        uint256 idle = IERC20(DEBT_TOKEN).balanceOf(address(this));
        require(idle > 0, "no idle debt tokens");
        uint256 amount = maxAmount > idle ? idle : maxAmount;
        AdapterRouter(router).repay(amount);
    }

    // ================================================================
    //                   BUFFER / FEES / BACKSTOP
    // ================================================================

    /// @notice Virtual protocol buffer: the gap between what users owe and
    ///         what is actually owed to external adapters. All surplus debt-token
    ///         proceeds are used to repay adapters; the resulting gap IS the buffer.
    function protocolBuffer() public view returns (uint256) {
        uint256 uDebt = totalUserDebt();
        uint256 extDebt = externalDebt();
        return uDebt > extDebt ? uDebt - extDebt : 0;
    }

    /// @notice Deposit debt tokens into the buffer (repays adapters).
    function depositBuffer(uint256 amount) external nonReentrant onlyKeeper {
        IERC20(DEBT_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        AdapterRouter(router).repay(amount);
    }

    /// @notice Deposit sponsor backstop in collateral token.
    function depositBackstop(uint256 amount) external nonReentrant onlyKeeper {
        require(amount > 0, "zero amount");
        IERC20(COLLATERAL_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        uint256 vaultShares = IYearnVault4626(YIELD_VAULT).deposit(amount, address(this));
        AdapterRouter(router).supplyCollateralAuto(vaultShares);
        sponsorBackstop += amount;
    }

    /// @notice Withdraw sponsor backstop. Governance only, with safety checks.
    function withdrawBackstop(uint256 amount, address receiver)
        external
        nonReentrant
        onlyGovernance
        whenNotPaused
        whenNotEmergency
    {
        require(amount > 0, "zero amount");
        require(sponsorBackstop >= amount, "insufficient backstop");
        require(carryGap() == 0, "carry gap exists");
        sponsorBackstop -= amount;
        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        IYearnVault4626(YIELD_VAULT).withdraw(amount, receiver, address(this));
    }

    /// @notice Take protocol fee from virtual buffer excess. Borrows from
    ///         adapters to extract the fee, shrinking the virtual buffer.
    function takeProtocolFee(uint256 amount) external nonReentrant onlyGovernance whenNotPaused whenNotEmergency {
        require(feeRecipient != address(0), "no fee recipient");
        require(carryGap() == 0, "carry gap exists");

        uint256 target = totalUserDebt() * feeActivationBufferBps / 10000;
        uint256 buffer = protocolBuffer();
        require(buffer > target, "buffer below target");
        uint256 excess = buffer - target;
        uint256 maxFee = excess * protocolFeeBps / 10000;
        require(amount <= maxFee, "exceeds fee cap");

        // borrow from adapters — increases external debt, shrinks virtual buffer
        AdapterRouter(router).borrow(amount, feeRecipient);
    }

    // ================================================================
    //                      EMERGENCY MODE
    // ================================================================

    /// @notice Sync state and enter emergency mode if conditions are met.
    function syncAndMaybeEnterEmergency() external onlyKeeper {
        if (emergencyMode) return;
        if (protocolBuffer() == 0 && sponsorBackstop == 0 && externalDebt() > totalUserDebt()) {
            emergencyMode = true;
        }
    }

    function forceEmergencyMode() external onlyGovernance {
        emergencyMode = true;
    }

    function clearEmergencyMode() external onlyGovernance {
        require(emergencyMode, "not in emergency");
        require(externalDebt() <= totalUserDebt(), "carry gap remains");
        emergencyMode = false;
    }

    function capitalizeEmergencyShortfall() external nonReentrant onlyKeeper {
        require(emergencyMode, "not emergency");
        require(totalDebtShares > 0, "no debt shares");
        uint256 extDebt = externalDebt();
        uint256 uDebt = totalUserDebt();
        require(extDebt > uDebt, "no shortfall");
        debtIndex += (extDebt - uDebt) * 1e18 / totalDebtShares;
    }

    // ================================================================
    //                      PAUSE / ADMIN
    // ================================================================

    function pause() external onlyGuardian {
        paused = true;
    }

    function unpause() external onlyGovernance {
        paused = false;
    }

    function setOracle(address _oracle) external onlyGovernance {
        require(_oracle != address(0), "zero address");
        oracle = _oracle;
    }

    function setRouter(address _router) external onlyGovernance {
        require(_router != address(0), "zero address");
        router = _router;
        IERC20(YIELD_VAULT).forceApprove(_router, type(uint256).max);
        IERC20(DEBT_TOKEN).forceApprove(_router, type(uint256).max);
    }

    function setAuction(address _auction) external onlyGovernance {
        yearnAuction = _auction;
    }

    function setFeeRecipient(address _recipient) external onlyGovernance {
        feeRecipient = _recipient;
    }

    function setMaxBorrowLtvBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 9500, "too high");
        maxBorrowLtvBps = _bps;
    }

    function setLiquidationLtvBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 9900, "too high");
        liquidationLtvBps = _bps;
    }

    function setLiquidationBonusBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 2000, "too high");
        liquidationBonusBps = _bps;
    }

    function setFeeActivationBufferBps(uint256 _bps) external onlyGovernance {
        feeActivationBufferBps = _bps;
    }

    function setProtocolFeeBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 5000, "too high");
        protocolFeeBps = _bps;
    }

    function setMinAuctionLot(uint256 _min) external onlyGovernance {
        minAuctionLot = _min;
    }

    function setAuthority(address _authority) external onlyGovernance {
        require(_authority != address(0), "zero address");
        authority = _authority;
    }

    function setAuctionStartingPriceBps(uint256 _bps) external onlyGovernance {
        require(_bps >= 10000, "below oracle");
        auctionStartingPriceBps = _bps;
    }

    function setAuctionSlippageBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 5000, "too high");
        auctionSlippageBps = _bps;
    }

    function setAuctionDecayRate(uint256 _bps) external onlyGovernance {
        require(_bps > 0 && _bps < 10000, "invalid");
        auctionDecayRate = _bps;
    }

    // --- governance emergency tools ---

    function manualRepayAdapter(address adapter, uint256 amount) external nonReentrant onlyGovernance {
        AdapterRouter(router).repayAdapter(adapter, amount);
    }

    /// @notice Delever using any idle debt tokens sitting in the pool.
    function manualDelever(uint256 amount) external nonReentrant onlyGovernance {
        uint256 idle = IERC20(DEBT_TOKEN).balanceOf(address(this));
        require(amount <= idle, "insufficient idle");
        AdapterRouter(router).repay(amount);
    }

    function sweepNonCoreToken(address token, address to, uint256 amount) external onlyGovernance {
        require(token != COLLATERAL_TOKEN, "cannot sweep collateral");
        require(token != DEBT_TOKEN, "cannot sweep debt token");
        require(token != YIELD_VAULT, "cannot sweep yield vault");
        IERC20(token).safeTransfer(to, amount);
    }

    // ================================================================
    //                       VIEW HELPERS
    // ================================================================

    function userDebt(address user) public view returns (uint256) {
        return positions[user].debtShares * debtIndex / 1e18;
    }

    function totalUserDebt() public view returns (uint256) {
        return totalDebtShares * debtIndex / 1e18;
    }

    function totalVaultShares() public view returns (uint256) {
        return IERC20(YIELD_VAULT).balanceOf(address(this)) + AdapterRouter(router).totalCollateralShares();
    }

    function totalUnderlying() public view returns (uint256) {
        return IYearnVault4626(YIELD_VAULT).convertToAssets(totalVaultShares());
    }

    function requiredBacking() public view returns (uint256) {
        return totalPrincipal + sponsorBackstop;
    }

    function harvestableSurplus() public view returns (uint256) {
        uint256 underlying = totalUnderlying();
        uint256 required = requiredBacking();
        return underlying > required ? underlying - required : 0;
    }

    function externalDebt() public view returns (uint256) {
        return AdapterRouter(router).totalDebt();
    }

    function carryGap() public view returns (uint256) {
        uint256 extDebt = externalDebt();
        uint256 uDebt = totalUserDebt();
        return extDebt > uDebt ? extDebt - uDebt : 0;
    }

    function userCollateralValue(address user) public view returns (uint256) {
        return IPriceOracle(oracle).quote(positions[user].principal);
    }

    // ================================================================
    //                       INTERNAL
    // ================================================================

    function _deposit(address user, uint256 amount) internal {
        require(amount > 0, "zero amount");
        IERC20(COLLATERAL_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        uint256 vaultShares = IYearnVault4626(YIELD_VAULT).deposit(amount, address(this));
        AdapterRouter(router).supplyCollateralAuto(vaultShares);
        positions[user].principal += amount;
        totalPrincipal += amount;
    }

    function _borrow(address user, uint256 amount, address receiver) internal {
        require(amount > 0, "zero amount");
        uint256 shares = amount * 1e18 / debtIndex;
        require(shares > 0, "shares zero");
        positions[user].debtShares += shares;
        totalDebtShares += shares;
        require(_userLtvBps(user) <= maxBorrowLtvBps, "ltv exceeded");
        AdapterRouter(router).borrow(amount, receiver);
    }

    function _withdraw(address user, uint256 amount, address receiver) internal {
        require(amount > 0, "zero amount");
        Position storage pos = positions[user];
        require(pos.principal >= amount, "insufficient principal");
        pos.principal -= amount;
        totalPrincipal -= amount;
        if (pos.debtShares > 0) {
            require(_userLtvBps(user) <= maxBorrowLtvBps, "ltv exceeded");
        }
        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        IYearnVault4626(YIELD_VAULT).withdraw(amount, receiver, address(this));
    }

    function _repayFor(address user, uint256 amount) internal {
        require(amount > 0, "zero amount");
        Position storage pos = positions[user];
        uint256 currentDebt = pos.debtShares * debtIndex / 1e18;
        if (amount > currentDebt) amount = currentDebt;
        IERC20(DEBT_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        AdapterRouter(router).repay(amount);
        uint256 sharesBurned = amount * 1e18 / debtIndex;
        pos.debtShares -= sharesBurned;
        totalDebtShares -= sharesBurned;
    }

    function _userLtvBps(address user) internal view returns (uint256) {
        Position storage pos = positions[user];
        if (pos.principal == 0) return type(uint256).max;
        uint256 debt = pos.debtShares * debtIndex / 1e18;
        if (debt == 0) return 0;
        uint256 colValue = IPriceOracle(oracle).quote(pos.principal);
        require(colValue > 0, "oracle: zero value");
        return debt * 10000 / colValue;
    }

    function _debtToCollateral(uint256 debtValue) internal view returns (uint256) {
        uint256 oneUnit = 10 ** COLLATERAL_DECIMALS;
        uint256 pricePerUnit = IPriceOracle(oracle).quote(oneUnit);
        require(pricePerUnit > 0, "oracle: zero price");
        return debtValue * oneUnit / pricePerUnit;
    }

    function _ceilConvertToShares(uint256 assets) internal view returns (uint256) {
        uint256 shares = IYearnVault4626(YIELD_VAULT).convertToShares(assets);
        if (IYearnVault4626(YIELD_VAULT).convertToAssets(shares) < assets) shares += 1;
        return shares;
    }

    function _configureAndKickAuction(uint256 redeemed) internal {
        IYearnAuction auction_ = IYearnAuction(yearnAuction);
        if (auction_.isActive(COLLATERAL_TOKEN)) {
            if (IERC20(COLLATERAL_TOKEN).balanceOf(yearnAuction) == 0) {
                auction_.settle(COLLATERAL_TOKEN);
            } else {
                revert("auction active");
            }
        }
        _setAuctionPricing(redeemed);
        IERC20(COLLATERAL_TOKEN).safeTransfer(yearnAuction, redeemed);
        auction_.kick(COLLATERAL_TOKEN);
    }

    function _setAuctionPricing(uint256 _amount) internal {
        IYearnAuction auction_ = IYearnAuction(yearnAuction);
        uint256 fromUnit = 10 ** COLLATERAL_DECIMALS;
        uint256 oraclePrice = IPriceOracle(oracle).quote(fromUnit);
        uint256 targetPrice = Math.mulDiv(oraclePrice, 1e18, 10 ** DEBT_DECIMALS);

        uint256 startUnitPrice = Math.mulDiv(targetPrice, auctionStartingPriceBps, 10000, Math.Rounding.Ceil);
        uint256 startingPrice = Math.mulDiv(_amount, startUnitPrice, fromUnit * 1e18, Math.Rounding.Ceil);
        if (startingPrice == 0) startingPrice = 1;
        uint256 minimumPrice = Math.mulDiv(targetPrice, 10000 - auctionSlippageBps, 10000);

        if (auction_.startingPrice() != startingPrice) auction_.setStartingPrice(startingPrice);
        if (auction_.minimumPrice() != minimumPrice) auction_.setMinimumPrice(minimumPrice);
        if (auction_.stepDecayRate() != auctionDecayRate) auction_.setStepDecayRate(auctionDecayRate);
    }
}
