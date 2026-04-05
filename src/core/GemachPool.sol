// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    address public feeRecipient;

    uint256 public maxBorrowLtvBps;
    uint256 public liquidationLtvBps;
    uint256 public liquidationBonusBps;

    uint256 public feeActivationBufferBps;
    uint256 public protocolFeeBps;
    uint256 public minAuctionLot;

    /// @notice Auction starting price as bps of oracle price (e.g. 10050 = 100.5%).
    uint256 public auctionStartingPriceBps;
    /// @notice Maximum slippage below oracle for auction floor price in bps (e.g. 50 = 0.5%).
    uint256 public auctionSlippageBps;
    /// @notice Auction step decay rate in bps per step (e.g. 50 = 0.5%).
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
        collateralToken = _collateralToken;
        debtToken = _debtToken;
        yieldVault = _yieldVault;
        router = _router;
        oracle = _oracle;
        debtIndex = 1e18;

        // auction pricing defaults (matching BaseConvertor)
        auctionStartingPriceBps = 10050; // 100.5% of oracle
        auctionSlippageBps = 50;         // 0.5% below oracle floor
        auctionDecayRate = 50;           // 0.5% decay per step

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
    //                        USER FLOWS
    // ================================================================

    /// @notice Deposit collateral.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "zero amount");
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 vaultShares = IYearnVault4626(yieldVault).deposit(amount, address(this));
        AdapterRouter(router).supplyCollateralAuto(vaultShares);
        positions[msg.sender].principal += amount;
        totalPrincipal += amount;
    }

    /// @notice Borrow debt tokens against deposited collateral.
    function borrow(uint256 amount, address receiver) external nonReentrant whenNotPaused whenNotEmergency {
        require(amount > 0, "zero amount");
        uint256 shares = amount * 1e18 / debtIndex;
        require(shares > 0, "shares zero");
        positions[msg.sender].debtShares += shares;
        totalDebtShares += shares;
        require(_userLtvBps(msg.sender) <= maxBorrowLtvBps, "ltv exceeded");
        AdapterRouter(router).borrow(amount, receiver);
    }

    /// @notice Combined deposit + borrow convenience function.
    function depositAndBorrow(uint256 depositAmount, uint256 borrowAmount, address receiver) external nonReentrant whenNotPaused whenNotEmergency {
        require(depositAmount > 0, "zero deposit");
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), depositAmount);
        uint256 vaultShares = IYearnVault4626(yieldVault).deposit(depositAmount, address(this));
        AdapterRouter(router).supplyCollateralAuto(vaultShares);
        positions[msg.sender].principal += depositAmount;
        totalPrincipal += depositAmount;

        require(borrowAmount > 0, "zero borrow");
        uint256 shares = borrowAmount * 1e18 / debtIndex;
        require(shares > 0, "shares zero");
        positions[msg.sender].debtShares += shares;
        totalDebtShares += shares;
        require(_userLtvBps(msg.sender) <= maxBorrowLtvBps, "ltv exceeded");
        AdapterRouter(router).borrow(borrowAmount, receiver);
    }

    /// @notice Repay debt.
    function repay(uint256 amount) external nonReentrant {
        _repayFor(msg.sender, amount);
    }

    /// @notice Repay debt on behalf of another user.
    function repayFor(address user, uint256 amount) external nonReentrant {
        _repayFor(user, amount);
    }

    /// @notice Withdraw collateral.
    function withdraw(uint256 amount, address receiver) external nonReentrant whenNotPaused {
        require(amount > 0, "zero amount");
        Position storage pos = positions[msg.sender];
        require(pos.principal >= amount, "insufficient principal");

        pos.principal -= amount;
        totalPrincipal -= amount;

        if (pos.debtShares > 0) {
            require(_userLtvBps(msg.sender) <= maxBorrowLtvBps, "ltv exceeded");
        }

        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        IYearnVault4626(yieldVault).withdraw(amount, receiver, address(this));
    }

    // ================================================================
    //                        LIQUIDATION
    // ================================================================

    /// @notice Liquidate an unhealthy position.
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
        if (repayAmount > currentDebt) repayAmount = currentDebt;

        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), repayAmount);
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
            IYearnVault4626(yieldVault).withdraw(seizedCollateral, receiver, address(this));
        } else {
            IERC20(yieldVault).safeTransfer(receiver, sharesNeeded);
        }
    }

    // ================================================================
    //              YEARN AUCTION v1.0.4 INTEGRATION
    // ================================================================

    /// @notice Push harvestable surplus to the Yearn auction and kick it.
    ///         Sets auction pricing based on oracle (BaseConvertor pattern).
    /// @param maxAmount Maximum collateral to push.
    function pushSurplusToAuction(uint256 maxAmount) external nonReentrant onlyKeeper {
        require(yearnAuction != address(0), "no auction");
        uint256 surplus = harvestableSurplus();
        require(surplus > 0, "no surplus");

        uint256 amount = maxAmount > surplus ? surplus : maxAmount;
        require(amount >= minAuctionLot, "below min lot");

        // pull vault shares from router, redeem to collateral
        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        uint256 redeemed = IYearnVault4626(yieldVault).redeem(
            IERC20(yieldVault).balanceOf(address(this)), address(this), address(this)
        );

        _configureAndKickAuction(redeemed);
    }

    /// @notice Sell protocol sponsor backstop via Yearn auction.
    /// @param maxAmount Maximum collateral to sell from backstop.
    function sellBackstopToAuction(uint256 maxAmount) external nonReentrant onlyKeeper {
        require(yearnAuction != address(0), "no auction");
        require(sponsorBackstop > 0, "no backstop");

        uint256 amount = maxAmount > sponsorBackstop ? sponsorBackstop : maxAmount;
        require(amount >= minAuctionLot, "below min lot");
        sponsorBackstop -= amount;

        uint256 sharesNeeded = _ceilConvertToShares(amount);
        AdapterRouter(router).withdrawCollateralShares(sharesNeeded, address(this));
        uint256 redeemed = IYearnVault4626(yieldVault).redeem(
            IERC20(yieldVault).balanceOf(address(this)), address(this), address(this)
        );

        _configureAndKickAuction(redeemed);
    }

    /// @notice Kick an auction for collateral already sitting in the auction contract.
    ///         Useful if tokens were transferred but the auction wasn't kicked yet.
    function kickAuction() external onlyKeeper {
        require(yearnAuction != address(0), "no auction");
        IYearnAuction auction_ = IYearnAuction(yearnAuction);
        require(!auction_.isActive(collateralToken), "auction active");
        uint256 kickableAmt = auction_.kickable(collateralToken);
        require(kickableAmt > 0, "nothing to kick");
        _setAuctionPricing(kickableAmt);
        auction_.kick(collateralToken);
    }

    /// @notice Route idle debt tokens in the pool to repay highest-cost adapter(s).
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

    /// @notice Deposit debt tokens directly into the buffer.
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

    /// @notice Capitalize uncovered shortfall onto borrowers.
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

    function pause() external onlyGuardian { paused = true; }
    function unpause() external onlyGovernance { paused = false; }

    // --- governance setters ---

    function setOracle(address _oracle) external onlyGovernance {
        require(_oracle != address(0), "zero address");
        oracle = _oracle;
    }

    function setRouter(address _router) external onlyGovernance {
        require(_router != address(0), "zero address");
        router = _router;
        IERC20(yieldVault).forceApprove(_router, type(uint256).max);
        IERC20(debtToken).forceApprove(_router, type(uint256).max);
    }

    /// @notice Set the Yearn auction address. The auction must have the pool as
    ///         governance and the pool as receiver, with collateralToken enabled.
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

    /// @notice Set auction starting price in bps of oracle price (e.g. 10050 = 100.5%).
    function setAuctionStartingPriceBps(uint256 _bps) external onlyGovernance {
        require(_bps >= 10000, "below oracle");
        auctionStartingPriceBps = _bps;
    }

    /// @notice Set max slippage below oracle for auction floor in bps.
    function setAuctionSlippageBps(uint256 _bps) external onlyGovernance {
        require(_bps <= 5000, "too high");
        auctionSlippageBps = _bps;
    }

    /// @notice Set auction decay rate per step in bps.
    function setAuctionDecayRate(uint256 _bps) external onlyGovernance {
        require(_bps > 0 && _bps < 10000, "invalid");
        auctionDecayRate = _bps;
    }

    // --- governance emergency tools ---

    function manualRepayAdapter(address adapter, uint256 amount) external nonReentrant onlyGovernance {
        AdapterRouter(router).repayAdapter(adapter, amount);
    }

    function manualDelever(uint256 amount) external nonReentrant onlyGovernance {
        uint256 idle = bufferBalance();
        require(amount <= idle, "insufficient buffer");
        AdapterRouter(router).repay(amount);
    }

    function sweepNonCoreToken(address token, address to, uint256 amount) external onlyGovernance {
        require(token != collateralToken, "cannot sweep collateral");
        require(token != debtToken, "cannot sweep debt token");
        require(token != yieldVault, "cannot sweep yield vault");
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
        return IERC20(yieldVault).balanceOf(address(this)) + AdapterRouter(router).totalCollateralShares();
    }

    function totalUnderlying() public view returns (uint256) {
        return IYearnVault4626(yieldVault).convertToAssets(totalVaultShares());
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
        uint256 oneUnit = 10 ** _collateralDecimals();
        uint256 pricePerUnit = IPriceOracle(oracle).quote(oneUnit);
        require(pricePerUnit > 0, "oracle: zero price");
        return debtValue * oneUnit / pricePerUnit;
    }

    function _ceilConvertToShares(uint256 assets) internal view returns (uint256) {
        uint256 shares = IYearnVault4626(yieldVault).convertToShares(assets);
        if (IYearnVault4626(yieldVault).convertToAssets(shares) < assets) {
            shares += 1;
        }
        return shares;
    }

    function _collateralDecimals() internal view returns (uint8) {
        (bool ok, bytes memory ret) = collateralToken.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (ok && ret.length >= 32) return abi.decode(ret, (uint8));
        return 18;
    }

    function _debtTokenDecimals() internal view returns (uint8) {
        (bool ok, bytes memory ret) = debtToken.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (ok && ret.length >= 32) return abi.decode(ret, (uint8));
        return 18;
    }

    /// @dev Configure auction pricing and kick. Follows BaseConvertor pattern.
    ///      Transfers collateral to auction, sets startingPrice / minimumPrice /
    ///      stepDecayRate based on oracle, then kicks.
    function _configureAndKickAuction(uint256 redeemed) internal {
        IYearnAuction auction_ = IYearnAuction(yearnAuction);

        // settle previous auction if it completed (balance 0)
        if (auction_.isActive(collateralToken)) {
            if (IERC20(collateralToken).balanceOf(yearnAuction) == 0) {
                auction_.settle(collateralToken);
            } else {
                revert("auction active");
            }
        }

        // set pricing
        _setAuctionPricing(redeemed);

        // transfer collateral to auction and kick
        IERC20(collateralToken).safeTransfer(yearnAuction, redeemed);
        auction_.kick(collateralToken);
    }

    /// @dev Calculates and sets auction pricing on the Yearn Auction contract.
    ///      Based on the BaseConvertor._auctionPricingFor pattern:
    ///      - targetPrice = oracle price of 1 collateral unit, scaled to 1e18
    ///      - startingPrice (lot-size) = amount * (targetPrice * startingBps / 10000) / (unit * 1e18)
    ///      - minimumPrice = targetPrice * (10000 - slippageBps) / 10000
    function _setAuctionPricing(uint256 _amount) internal {
        IYearnAuction auction_ = IYearnAuction(yearnAuction);

        uint256 colDecimals = _collateralDecimals();
        uint256 debtDecimals = _debtTokenDecimals();
        uint256 fromUnit = 10 ** colDecimals;

        // targetPrice: oracle price of 1 collateral unit, scaled to 1e18
        uint256 oraclePrice = IPriceOracle(oracle).quote(fromUnit);
        uint256 targetPrice = Math.mulDiv(oraclePrice, 1e18, 10 ** debtDecimals);

        // startingPrice (lot-size): above market
        uint256 startUnitPrice = Math.mulDiv(
            targetPrice, auctionStartingPriceBps, 10000, Math.Rounding.Ceil
        );
        uint256 startingPrice = Math.mulDiv(
            _amount, startUnitPrice, fromUnit * 1e18, Math.Rounding.Ceil
        );
        if (startingPrice == 0) startingPrice = 1;

        // minimumPrice: floor below market
        uint256 minimumPrice = Math.mulDiv(
            targetPrice, 10000 - auctionSlippageBps, 10000
        );

        // apply to auction
        if (auction_.startingPrice() != startingPrice) {
            auction_.setStartingPrice(startingPrice);
        }
        if (auction_.minimumPrice() != minimumPrice) {
            auction_.setMinimumPrice(minimumPrice);
        }
        if (auction_.stepDecayRate() != auctionDecayRate) {
            auction_.setStepDecayRate(auctionDecayRate);
        }
    }
}
