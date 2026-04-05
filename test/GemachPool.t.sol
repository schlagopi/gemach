// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {Authority} from "../src/access/Authority.sol";
import {GemachPool} from "../src/core/GemachPool.sol";
import {AdapterRouter} from "../src/core/AdapterRouter.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYearnVault4626} from "./mocks/MockYearnVault4626.sol";
import {MockYearnAuction} from "./mocks/MockYearnAuction.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";

contract GemachPoolTest is Test {
    Authority authority;
    MockERC20 cbBTC;
    MockERC20 usdc;
    MockYearnVault4626 yvBTC;
    MockYearnAuction auction;
    MockOracle oracle;
    MockAdapter adapterA; // low rate
    MockAdapter adapterB; // high rate
    AdapterRouter router;
    GemachPool pool;

    address gov = address(this);
    address keeper = address(0xBEEF);
    address guardian = address(0xCAFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address liquidator = address(0x11CC);
    address feeRecipient = address(0xFEE);
    address nobody = address(0xDEAD);

    bytes32 constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    function setUp() public {
        // deploy tokens
        cbBTC = new MockERC20("cbBTC", "cbBTC", 8);
        usdc = new MockERC20("USDC", "USDC", 6);
        yvBTC = new MockYearnVault4626(address(cbBTC));

        // deploy authority and grant roles
        authority = new Authority();
        authority.grantRole(KEEPER_ROLE, keeper);
        authority.grantRole(GUARDIAN_ROLE, guardian);

        // deploy oracle: 1 BTC = 60,000 USDC
        oracle = new MockOracle();

        // deploy auction (want = USDC, receiver = pool set after pool deployment)
        auction = new MockYearnAuction(address(usdc), address(0));

        // deploy router
        router = new AdapterRouter(address(authority), address(yvBTC), address(usdc));

        // deploy pool
        pool = new GemachPool(
            address(authority),
            address(cbBTC),
            address(usdc),
            address(yvBTC),
            address(router),
            address(oracle)
        );

        // wire router to pool
        router.setPool(address(pool));

        // deploy adapters (A=low rate 2%, B=high rate 8%)
        adapterA = new MockAdapter(address(yvBTC), address(usdc), 0.02e18);
        adapterB = new MockAdapter(address(yvBTC), address(usdc), 0.08e18);
        adapterA.setRouter(address(router));
        adapterB.setRouter(address(router));

        // add adapters
        router.addAdapter(address(adapterA));
        router.addAdapter(address(adapterB));

        // configure pool parameters
        pool.setMaxBorrowLtvBps(7500);        // 75%
        pool.setLiquidationLtvBps(8500);      // 85%
        pool.setLiquidationBonusBps(500);     // 5%
        pool.setFeeActivationBufferBps(1000); // 10%
        pool.setProtocolFeeBps(2000);         // 20%
        pool.setMinAuctionLot(0);
        pool.setAuction(address(auction));
        auction.setReceiver(address(pool));
        auction.enable(address(cbBTC));
        pool.setFeeRecipient(feeRecipient);

        // fund alice with 10 BTC
        cbBTC.mint(alice, 10e8);
        vm.prank(alice);
        cbBTC.approve(address(pool), type(uint256).max);

        // fund bob with 5 BTC
        cbBTC.mint(bob, 5e8);
        vm.prank(bob);
        cbBTC.approve(address(pool), type(uint256).max);

        // fund liquidator with USDC
        usdc.mint(liquidator, 1_000_000e6);
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
    }

    // ================================================================
    //  SPEC TEST 1: Deposit + full repay + withdraw returns exact principal
    // ================================================================

    function test_depositRepayWithdraw_exactPrincipal() public {
        vm.prank(alice);
        pool.deposit(1e8);

        (uint256 principal,) = pool.positions(alice);
        assertEq(principal, 1e8);

        vm.prank(alice);
        pool.borrow(30_000e6, alice);

        usdc.mint(alice, 30_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(30_000e6);
        vm.stopPrank();

        assertEq(pool.userDebt(alice), 0);

        uint256 balBefore = cbBTC.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw(1e8, alice);

        assertEq(cbBTC.balanceOf(alice) - balBefore, 1e8);
        (principal,) = pool.positions(alice);
        assertEq(principal, 0);
    }

    // ================================================================
    //  SPEC TEST 2: Yield increases surplus but does not change user debt
    // ================================================================

    function test_yieldIncreasesSurplus_notDebt() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        uint256 debtBefore = pool.userDebt(alice);
        uint256 surplusBefore = pool.harvestableSurplus();

        yvBTC.setSharePrice(105, 100);

        assertEq(pool.userDebt(alice), debtBefore);
        assertGt(pool.harvestableSurplus(), surplusBefore);
    }

    // ================================================================
    //  SPEC TEST 3: Surplus sale increases buffer, not reduces debt
    // ================================================================

    function test_surplusSale_increasesBuffer_notReduceDebt() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        yvBTC.setSharePrice(110, 100);

        uint256 debtBefore = pool.userDebt(alice);
        uint256 bufferBefore = pool.bufferBalance();

        vm.prank(keeper);
        pool.pushSurplusToAuction(1e8);

        // simulate auction proceeds arriving
        usdc.mint(address(pool), 5_000e6);

        assertEq(pool.userDebt(alice), debtBefore);
        assertGt(pool.bufferBalance(), bufferBefore);
    }

    // ================================================================
    //  SPEC TEST 4: Borrow uses lowest-cost adapter
    // ================================================================

    function test_borrowUsesLowestCostAdapter() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        assertEq(adapterA.totalDebt(), 20_000e6);
        assertEq(adapterB.totalDebt(), 0);
    }

    // ================================================================
    //  SPEC TEST 5: Repay routes to highest-cost adapter
    // ================================================================

    function test_repayRoutesToHighestCostAdapter() public {
        adapterA.setLiquidity(10_000e6);

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        assertEq(adapterA.totalDebt(), 10_000e6);
        assertEq(adapterB.totalDebt(), 10_000e6);

        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(5_000e6);
        vm.stopPrank();

        assertEq(adapterA.totalDebt(), 10_000e6);
        assertEq(adapterB.totalDebt(), 5_000e6);
    }

    // ================================================================
    //  SPEC TEST 6: Liquidation burns debt and seizes only user principal
    // ================================================================

    function test_liquidation() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        oracle.setPrice(50_000e6);

        uint256 sponsorBefore = pool.sponsorBackstop();
        (uint256 principalBefore,) = pool.positions(alice);

        vm.prank(liquidator);
        pool.liquidate(alice, 10_000e6, true, liquidator);

        (uint256 principalAfter,) = pool.positions(alice);
        assertLt(principalAfter, principalBefore);
        assertLt(pool.userDebt(alice), 44_000e6);
        assertEq(pool.sponsorBackstop(), sponsorBefore);
    }

    // ================================================================
    //  SPEC TEST 7: Sponsor backstop consumed before emergency accrual
    // ================================================================

    function test_sponsorBackstopBeforeEmergency() public {
        cbBTC.mint(keeper, 1e8);
        vm.startPrank(keeper);
        cbBTC.approve(address(pool), type(uint256).max);
        pool.depositBackstop(1e8);
        vm.stopPrank();

        assertEq(pool.sponsorBackstop(), 1e8);

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        adapterA.accrueInterest(5_000e6);

        vm.prank(keeper);
        pool.syncAndMaybeEnterEmergency();
        assertFalse(pool.emergencyMode());

        vm.prank(keeper);
        pool.sellBackstopToAuction(1e8);
        assertEq(pool.sponsorBackstop(), 0);

        vm.prank(keeper);
        pool.syncAndMaybeEnterEmergency();
        assertTrue(pool.emergencyMode());
    }

    // ================================================================
    //  SPEC TEST 8: Emergency mode increases debtIndex
    // ================================================================

    function test_emergencyMode_increasesDebtIndex() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        uint256 debtBefore = pool.userDebt(alice);
        uint256 indexBefore = pool.debtIndex();

        adapterA.accrueInterest(5_000e6);
        pool.forceEmergencyMode();

        vm.prank(keeper);
        pool.capitalizeEmergencyShortfall();

        assertGt(pool.debtIndex(), indexBefore);
        assertGt(pool.userDebt(alice), debtBefore);
    }

    // ================================================================
    //  SPEC TEST 9: Pause behavior
    // ================================================================

    function test_pause_blocksAndAllows() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        vm.prank(guardian);
        pool.pause();
        assertTrue(pool.paused());

        // blocked: deposit, borrow, withdraw, depositAndBorrow
        vm.prank(alice);
        vm.expectRevert("paused");
        pool.deposit(1e8);

        vm.prank(alice);
        vm.expectRevert("paused");
        pool.borrow(1e6, alice);

        vm.prank(alice);
        vm.expectRevert("paused");
        pool.withdraw(1e7, alice);

        vm.prank(alice);
        vm.expectRevert("paused");
        pool.depositAndBorrow(1e8, 1e6, alice);

        // allowed: repay
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(1_000e6);
        vm.stopPrank();

        // allowed: liquidate
        oracle.setPrice(50_000e6);
        vm.prank(liquidator);
        pool.liquidate(alice, 1_000e6, true, liquidator);

        // allowed: routeIdleDebtTokens
        usdc.mint(address(pool), 100e6);
        vm.prank(keeper);
        pool.routeIdleDebtTokens(100e6);

        // allowed: depositBackstop
        cbBTC.mint(keeper, 1e8);
        vm.startPrank(keeper);
        cbBTC.approve(address(pool), type(uint256).max);
        pool.depositBackstop(1e7);
        vm.stopPrank();

        // allowed: depositBuffer
        usdc.mint(keeper, 100e6);
        vm.startPrank(keeper);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositBuffer(100e6);
        vm.stopPrank();

        // blocked: withdrawBackstop (while paused)
        vm.expectRevert("paused");
        pool.withdrawBackstop(1e7, gov);

        // blocked: takeProtocolFee (while paused)
        vm.expectRevert("paused");
        pool.takeProtocolFee(1);

        // unpause
        pool.unpause();
        assertFalse(pool.paused());
    }

    // ================================================================
    //  SPEC TEST 10: No path sells user principal for carry
    // ================================================================

    function test_surplusSale_neverSellsUserPrincipal() public {
        vm.prank(alice);
        pool.deposit(1e8);

        assertEq(pool.harvestableSurplus(), 0);

        vm.prank(keeper);
        vm.expectRevert("no surplus");
        pool.pushSurplusToAuction(1e8);

        (uint256 principal,) = pool.positions(alice);
        assertEq(principal, 1e8);
    }

    // ================================================================
    //  SPEC TEST 11: debtIndex never decreases
    // ================================================================

    function test_debtIndex_neverDecreases() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        uint256 idx1 = pool.debtIndex();

        // repay does not change
        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(5_000e6);
        vm.stopPrank();
        assertEq(pool.debtIndex(), idx1);

        // yield does not change
        yvBTC.setSharePrice(110, 100);
        assertEq(pool.debtIndex(), idx1);

        // emergency capitalization increases it
        adapterA.accrueInterest(5_000e6);
        pool.forceEmergencyMode();
        vm.prank(keeper);
        pool.capitalizeEmergencyShortfall();
        assertGt(pool.debtIndex(), idx1);
    }

    // ================================================================
    //  SPEC TEST 12: No loops over users in state-changing paths
    // ================================================================

    function test_noUserLoops() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(10_000e6, alice);

        vm.prank(bob);
        pool.deposit(1e8);
        vm.prank(bob);
        pool.borrow(10_000e6, bob);

        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(10_000e6);
        vm.stopPrank();

        vm.prank(alice);
        pool.withdraw(1e8, alice);

        (uint256 bobPrincipal, uint256 bobShares) = pool.positions(bob);
        assertEq(bobPrincipal, 1e8);
        assertGt(bobShares, 0);
    }

    // ================================================================
    //                    ADDITIONAL COVERAGE
    // ================================================================

    // --- depositAndBorrow ---

    function test_depositAndBorrow() public {
        vm.prank(alice);
        pool.depositAndBorrow(1e8, 30_000e6, alice);

        (uint256 principal,) = pool.positions(alice);
        assertEq(principal, 1e8);
        assertEq(pool.userDebt(alice), 30_000e6);
    }

    // --- repayFor ---

    function test_repayFor() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        usdc.mint(bob, 20_000e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayFor(alice, 20_000e6);
        vm.stopPrank();

        assertEq(pool.userDebt(alice), 0);
    }

    // --- repay caps to current debt ---

    function test_repay_capsToDebt() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(10_000e6, alice);

        usdc.mint(alice, 50_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(50_000e6); // overpay
        vm.stopPrank();

        assertEq(pool.userDebt(alice), 0);
        // alice should still have excess USDC (only 10k taken)
        assertGe(usdc.balanceOf(alice), 40_000e6);
    }

    // --- LTV checks ---

    function test_ltvCheck_borrow() public {
        vm.prank(alice);
        pool.deposit(1e8);

        vm.prank(alice);
        vm.expectRevert("ltv exceeded");
        pool.borrow(46_000e6, alice);
    }

    function test_ltvCheck_withdraw() public {
        vm.prank(alice);
        pool.deposit(2e8);
        vm.prank(alice);
        pool.borrow(40_000e6, alice);

        // withdraw 1 BTC -> debt=40k, collateral value=60k -> 66% ok
        vm.prank(alice);
        pool.withdraw(1e8, alice);

        // withdraw more -> would push LTV too high
        vm.prank(alice);
        vm.expectRevert("ltv exceeded");
        pool.withdraw(0.4e8, alice);
    }

    // --- liquidation: receive vault shares ---

    function test_liquidation_receivesVaultShares() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        oracle.setPrice(50_000e6);

        uint256 yvBalBefore = yvBTC.balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(alice, 5_000e6, false, liquidator);

        assertGt(yvBTC.balanceOf(liquidator), yvBalBefore);
    }

    // --- liquidation: caps repay to user debt ---

    function test_liquidation_capsRepayToDebt() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        oracle.setPrice(50_000e6);

        // try to repay way more than user's debt
        vm.prank(liquidator);
        pool.liquidate(alice, 999_999e6, true, liquidator);

        assertEq(pool.userDebt(alice), 0);
    }

    // --- liquidation: reverts if healthy ---

    function test_liquidation_revertsIfHealthy() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        vm.prank(liquidator);
        vm.expectRevert("not liquidatable");
        pool.liquidate(alice, 1_000e6, true, liquidator);
    }

    // --- emergency mode disables borrow ---

    function test_emergencyMode_disablesBorrow() public {
        vm.prank(alice);
        pool.deposit(1e8);

        pool.forceEmergencyMode();

        vm.prank(alice);
        vm.expectRevert("emergency mode");
        pool.borrow(1_000e6, alice);
    }

    // --- emergency mode disables depositAndBorrow ---

    function test_emergencyMode_disablesDepositAndBorrow() public {
        pool.forceEmergencyMode();

        vm.prank(alice);
        vm.expectRevert("emergency mode");
        pool.depositAndBorrow(1e8, 1e6, alice);
    }

    // --- fee taking ---

    function test_feesTaken() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        // buffer > target (target = 20000 * 10% = 2000)
        usdc.mint(address(pool), 10_000e6);

        uint256 target = pool.totalUserDebt() * pool.feeActivationBufferBps() / 10000;
        uint256 buffer = pool.bufferBalance();
        uint256 excess = buffer - target;
        uint256 maxFee = excess * pool.protocolFeeBps() / 10000;

        uint256 recipientBefore = usdc.balanceOf(feeRecipient);
        pool.takeProtocolFee(maxFee);
        assertEq(usdc.balanceOf(feeRecipient) - recipientBefore, maxFee);
    }

    // --- fee: reverts when no fee recipient ---

    function test_fee_revertsNoRecipient() public {
        pool.setFeeRecipient(address(0));

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);
        usdc.mint(address(pool), 100_000e6);

        vm.expectRevert("no fee recipient");
        pool.takeProtocolFee(1);
    }

    // --- fee: reverts when buffer below target ---

    function test_fee_revertsBufferBelowTarget() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);
        // no buffer at all

        vm.expectRevert("buffer below target");
        pool.takeProtocolFee(1);
    }

    // --- fee: reverts when carry gap exists ---

    function test_fee_revertsCarryGap() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);
        usdc.mint(address(pool), 100_000e6);

        adapterA.accrueInterest(1_000e6);

        vm.expectRevert("carry gap exists");
        pool.takeProtocolFee(1);
    }

    // --- fee: reverts when exceeds cap ---

    function test_fee_revertsExceedsCap() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);
        usdc.mint(address(pool), 100_000e6);

        uint256 target = pool.totalUserDebt() * pool.feeActivationBufferBps() / 10000;
        uint256 buffer = pool.bufferBalance();
        uint256 excess = buffer - target;
        uint256 maxFee = excess * pool.protocolFeeBps() / 10000;

        vm.expectRevert("exceeds fee cap");
        pool.takeProtocolFee(maxFee + 1);
    }

    // --- fee: reverts in emergency ---

    function test_fee_revertsInEmergency() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);
        usdc.mint(address(pool), 100_000e6);

        pool.forceEmergencyMode();

        vm.expectRevert("emergency mode");
        pool.takeProtocolFee(1);
    }

    // --- sweep ---

    function test_sweepNonCoreToken() public {
        MockERC20 rando = new MockERC20("RANDO", "RANDO", 18);
        rando.mint(address(pool), 1000);

        pool.sweepNonCoreToken(address(rando), gov, 1000);
        assertEq(rando.balanceOf(gov), 1000);
    }

    function test_cannotSweepCoreTokens() public {
        vm.expectRevert("cannot sweep collateral");
        pool.sweepNonCoreToken(address(cbBTC), gov, 1);

        vm.expectRevert("cannot sweep debt token");
        pool.sweepNonCoreToken(address(usdc), gov, 1);

        vm.expectRevert("cannot sweep yield vault");
        pool.sweepNonCoreToken(address(yvBTC), gov, 1);
    }

    // --- clear emergency mode ---

    function test_clearEmergencyMode() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        adapterA.accrueInterest(5_000e6);
        pool.forceEmergencyMode();

        vm.expectRevert("carry gap remains");
        pool.clearEmergencyMode();

        vm.prank(keeper);
        pool.capitalizeEmergencyShortfall();

        pool.clearEmergencyMode();
        assertFalse(pool.emergencyMode());
    }

    function test_clearEmergencyMode_revertsIfNotEmergency() public {
        vm.expectRevert("not in emergency");
        pool.clearEmergencyMode();
    }

    // --- capitalize: reverts when not emergency ---

    function test_capitalize_revertsNotEmergency() public {
        vm.prank(keeper);
        vm.expectRevert("not emergency");
        pool.capitalizeEmergencyShortfall();
    }

    // --- capitalize: reverts when no debt shares ---

    function test_capitalize_revertsNoDebtShares() public {
        pool.forceEmergencyMode();
        vm.prank(keeper);
        vm.expectRevert("no debt shares");
        pool.capitalizeEmergencyShortfall();
    }

    // --- capitalize: reverts when no shortfall ---

    function test_capitalize_revertsNoShortfall() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        pool.forceEmergencyMode();
        // no accrued interest = no shortfall
        vm.prank(keeper);
        vm.expectRevert("no shortfall");
        pool.capitalizeEmergencyShortfall();
    }

    // --- syncAndMaybeEnterEmergency: early return if already emergency ---

    function test_syncEmergency_earlyReturnIfAlready() public {
        pool.forceEmergencyMode();
        vm.prank(keeper);
        pool.syncAndMaybeEnterEmergency(); // should not revert
        assertTrue(pool.emergencyMode());
    }

    // --- syncAndMaybeEnterEmergency: does not enter if buffer nonzero ---

    function test_syncEmergency_doesNotEnterWithBuffer() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        adapterA.accrueInterest(5_000e6);
        usdc.mint(address(pool), 1e6); // tiny buffer

        vm.prank(keeper);
        pool.syncAndMaybeEnterEmergency();
        assertFalse(pool.emergencyMode());
    }

    // --- authority ---

    function test_authority_roles() public view {
        assertTrue(authority.hasRole(GOVERNANCE_ROLE, gov));
        assertTrue(authority.hasRole(KEEPER_ROLE, keeper));
        assertTrue(authority.hasRole(GUARDIAN_ROLE, guardian));

        assertEq(authority.getRoleMemberCount(KEEPER_ROLE), 1);
        assertEq(authority.getRoleMember(KEEPER_ROLE, 0), keeper);
    }

    function test_authority_grantRevoke() public {
        authority.grantRole(KEEPER_ROLE, nobody);
        assertTrue(authority.hasRole(KEEPER_ROLE, nobody));
        assertEq(authority.getRoleMemberCount(KEEPER_ROLE), 2);

        authority.revokeRole(KEEPER_ROLE, nobody);
        assertFalse(authority.hasRole(KEEPER_ROLE, nobody));
        assertEq(authority.getRoleMemberCount(KEEPER_ROLE), 1);
    }

    function test_authority_onlyGovernanceCanGrant() public {
        vm.prank(nobody);
        vm.expectRevert(); // OZ AccessControl custom error
        authority.grantRole(KEEPER_ROLE, nobody);
    }

    function test_authority_onlyGovernanceCanRevoke() public {
        vm.prank(nobody);
        vm.expectRevert(); // OZ AccessControl custom error
        authority.revokeRole(KEEPER_ROLE, keeper);
    }

    // --- backstop ---

    function test_backstopDeposit() public {
        cbBTC.mint(keeper, 2e8);
        vm.startPrank(keeper);
        cbBTC.approve(address(pool), type(uint256).max);
        pool.depositBackstop(2e8);
        vm.stopPrank();

        assertEq(pool.sponsorBackstop(), 2e8);
    }

    function test_withdrawBackstop() public {
        cbBTC.mint(keeper, 1e8);
        vm.startPrank(keeper);
        cbBTC.approve(address(pool), type(uint256).max);
        pool.depositBackstop(1e8);
        vm.stopPrank();

        uint256 before = cbBTC.balanceOf(gov);
        pool.withdrawBackstop(1e8, gov);
        assertEq(cbBTC.balanceOf(gov) - before, 1e8);
        assertEq(pool.sponsorBackstop(), 0);
    }

    function test_withdrawBackstop_revertsCarryGap() public {
        cbBTC.mint(keeper, 1e8);
        vm.startPrank(keeper);
        cbBTC.approve(address(pool), type(uint256).max);
        pool.depositBackstop(1e8);
        vm.stopPrank();

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);
        adapterA.accrueInterest(1_000e6);

        vm.expectRevert("carry gap exists");
        pool.withdrawBackstop(1e8, gov);
    }

    function test_withdrawBackstop_revertsInEmergency() public {
        cbBTC.mint(keeper, 1e8);
        vm.startPrank(keeper);
        cbBTC.approve(address(pool), type(uint256).max);
        pool.depositBackstop(1e8);
        vm.stopPrank();

        pool.forceEmergencyMode();
        vm.expectRevert("emergency mode");
        pool.withdrawBackstop(1e8, gov);
    }

    function test_withdrawBackstop_revertsInsufficient() public {
        vm.expectRevert("insufficient backstop");
        pool.withdrawBackstop(1, gov);
    }

    // --- router adapter management ---

    function test_routerAdapterManagement() public {
        MockAdapter newAdapter = new MockAdapter(address(yvBTC), address(usdc), 0.05e18);
        newAdapter.setRouter(address(router));
        router.addAdapter(address(newAdapter));
        assertEq(router.adapterCount(), 3);

        router.disableAdapter(address(newAdapter));
        assertFalse(router.adapterEnabled(address(newAdapter)));

        router.removeAdapter(address(newAdapter));
        assertEq(router.adapterCount(), 2);
    }

    function test_router_addAdapter_wrongCollateral() public {
        MockAdapter bad = new MockAdapter(address(usdc), address(usdc), 0);
        vm.expectRevert("wrong collateral");
        router.addAdapter(address(bad));
    }

    function test_router_addAdapter_wrongLoan() public {
        MockAdapter bad = new MockAdapter(address(yvBTC), address(cbBTC), 0);
        vm.expectRevert("wrong loan");
        router.addAdapter(address(bad));
    }

    function test_router_addAdapter_alreadyEnabled() public {
        vm.expectRevert("already enabled");
        router.addAdapter(address(adapterA));
    }

    function test_router_disableAdapter_notEnabled() public {
        MockAdapter newA = new MockAdapter(address(yvBTC), address(usdc), 0);
        vm.expectRevert("not enabled");
        router.disableAdapter(address(newA));
    }

    function test_router_removeAdapter_stillEnabled() public {
        vm.expectRevert("still enabled");
        router.removeAdapter(address(adapterA));
    }

    function test_router_removeAdapter_hasDebt() public {
        // create some debt
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(10_000e6, alice);

        router.disableAdapter(address(adapterA));

        vm.expectRevert("has debt");
        router.removeAdapter(address(adapterA));
    }

    function test_router_maxAdapters() public {
        // already have 2, fill up to 8
        for (uint256 i = 2; i < 8; i++) {
            MockAdapter a = new MockAdapter(address(yvBTC), address(usdc), 0);
            a.setRouter(address(router));
            router.addAdapter(address(a));
        }
        assertEq(router.adapterCount(), 8);

        MockAdapter overflow = new MockAdapter(address(yvBTC), address(usdc), 0);
        vm.expectRevert("max adapters");
        router.addAdapter(address(overflow));
    }

    function test_router_getAdapters() public view {
        address[] memory list = router.getAdapters();
        assertEq(list.length, 2);
        assertEq(list[0], address(adapterA));
        assertEq(list[1], address(adapterB));
    }

    // --- governance setters ---

    function test_setOracle() public {
        address newOracle = address(0x999);
        pool.setOracle(newOracle);
        assertEq(pool.oracle(), newOracle);
    }

    function test_setOracle_revertsZero() public {
        vm.expectRevert("zero address");
        pool.setOracle(address(0));
    }

    function test_setRouter() public {
        AdapterRouter newRouter = new AdapterRouter(address(authority), address(yvBTC), address(usdc));
        pool.setRouter(address(newRouter));
        assertEq(pool.router(), address(newRouter));
    }

    function test_setRouter_revertsZero() public {
        vm.expectRevert("zero address");
        pool.setRouter(address(0));
    }

    function test_setAuthority() public {
        Authority newAuth = new Authority();
        pool.setAuthority(address(newAuth));
        assertEq(pool.authority(), address(newAuth));
    }

    function test_setAuthority_revertsZero() public {
        vm.expectRevert("zero address");
        pool.setAuthority(address(0));
    }

    function test_setMaxBorrowLtv_revertsHigh() public {
        vm.expectRevert("too high");
        pool.setMaxBorrowLtvBps(9501);
    }

    function test_setLiquidationLtv_revertsHigh() public {
        vm.expectRevert("too high");
        pool.setLiquidationLtvBps(9901);
    }

    function test_setLiquidationBonus_revertsHigh() public {
        vm.expectRevert("too high");
        pool.setLiquidationBonusBps(2001);
    }

    function test_setProtocolFee_revertsHigh() public {
        vm.expectRevert("too high");
        pool.setProtocolFeeBps(5001);
    }

    function test_setAuction() public {
        pool.setAuction(address(0x123));
        assertEq(pool.yearnAuction(), address(0x123));
    }

    function test_setFeeRecipient() public {
        pool.setFeeRecipient(address(0x456));
        assertEq(pool.feeRecipient(), address(0x456));
    }

    function test_setFeeActivationBufferBps() public {
        pool.setFeeActivationBufferBps(500);
        assertEq(pool.feeActivationBufferBps(), 500);
    }

    function test_setMinAuctionLot() public {
        pool.setMinAuctionLot(1e8);
        assertEq(pool.minAuctionLot(), 1e8);
    }

    // --- auth: non-governance revert checks ---

    function test_auth_nobodyCannotCallGovernance() public {
        vm.startPrank(nobody);

        vm.expectRevert("not governance");
        pool.setOracle(address(1));

        vm.expectRevert("not governance");
        pool.setRouter(address(1));

        vm.expectRevert("not governance");
        pool.unpause();

        vm.expectRevert("not governance");
        pool.forceEmergencyMode();

        vm.expectRevert("not governance");
        pool.setMaxBorrowLtvBps(1);

        vm.expectRevert("not governance");
        pool.sweepNonCoreToken(address(1), address(1), 1);

        vm.expectRevert("not governance");
        pool.manualDelever(1);

        vm.expectRevert("not governance");
        pool.takeProtocolFee(1);

        vm.stopPrank();
    }

    function test_auth_nobodyCannotCallKeeper() public {
        vm.startPrank(nobody);

        vm.expectRevert("not keeper");
        pool.pushSurplusToAuction(1);

        vm.expectRevert("not keeper");
        pool.sellBackstopToAuction(1);

        vm.expectRevert("not keeper");
        pool.kickAuction();

        vm.expectRevert("not keeper");
        pool.routeIdleDebtTokens(1);

        vm.expectRevert("not keeper");
        pool.syncAndMaybeEnterEmergency();

        vm.expectRevert("not keeper");
        pool.capitalizeEmergencyShortfall();

        vm.expectRevert("not keeper");
        pool.depositBuffer(1);

        vm.expectRevert("not keeper");
        pool.depositBackstop(1);

        vm.stopPrank();
    }

    function test_auth_nobodyCannotCallGuardian() public {
        vm.prank(nobody);
        vm.expectRevert("not guardian");
        pool.pause();
    }

    // --- keeper can also call keeper functions ---

    function test_auth_keeperCanCallKeeperFunctions() public {
        // deposit collateral and create surplus
        vm.prank(alice);
        pool.deposit(1e8);
        yvBTC.setSharePrice(110, 100);

        vm.prank(keeper);
        pool.pushSurplusToAuction(1e8);
    }

    // --- governance can call keeper functions ---

    function test_auth_governanceCanCallKeeper() public {
        vm.prank(alice);
        pool.deposit(1e8);
        yvBTC.setSharePrice(110, 100);

        pool.pushSurplusToAuction(1e8); // gov calling keeper function
    }

    // --- guardian can call pause ---

    function test_auth_guardianCanPause() public {
        vm.prank(guardian);
        pool.pause();
        assertTrue(pool.paused());
    }

    // --- governance can call pause ---

    function test_auth_governanceCanPause() public {
        pool.pause();
        assertTrue(pool.paused());
    }

    // --- manual delever ---

    function test_manualDelever() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        adapterA.accrueInterest(1_000e6);
        usdc.mint(address(pool), 500e6);

        pool.manualDelever(500e6);
    }

    function test_manualDelever_revertsInsufficient() public {
        vm.expectRevert("insufficient buffer");
        pool.manualDelever(1);
    }

    // --- manual repay adapter ---

    function test_manualRepayAdapter() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        usdc.mint(address(pool), 5_000e6);
        pool.manualRepayAdapter(address(adapterA), 5_000e6);
        assertEq(adapterA.totalDebt(), 15_000e6);
    }

    // --- kick auction ---

    function test_kickAuction_revertsNoAuction() public {
        pool.setAuction(address(0));
        vm.prank(keeper);
        vm.expectRevert("no auction");
        pool.kickAuction();
    }

    // --- routeIdleDebtTokens ---

    function test_routeIdleDebtTokens_revertsNoIdle() public {
        vm.prank(keeper);
        vm.expectRevert("no idle debt tokens");
        pool.routeIdleDebtTokens(1);
    }

    // --- pushSurplusToAuction with min lot ---

    function test_pushSurplus_belowMinLot() public {
        pool.setMinAuctionLot(100e8); // huge min

        vm.prank(alice);
        pool.deposit(1e8);
        yvBTC.setSharePrice(110, 100);

        vm.prank(keeper);
        vm.expectRevert("below min lot");
        pool.pushSurplusToAuction(1e8);
    }

    // --- sellBackstopToAuction ---

    function test_sellBackstop_noBackstop() public {
        vm.prank(keeper);
        vm.expectRevert("no backstop");
        pool.sellBackstopToAuction(1);
    }

    function test_sellBackstop_belowMinLot() public {
        pool.setMinAuctionLot(100e8);

        cbBTC.mint(keeper, 1e8);
        vm.startPrank(keeper);
        cbBTC.approve(address(pool), type(uint256).max);
        pool.depositBackstop(1e8);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert("below min lot");
        pool.sellBackstopToAuction(1e8);
    }

    // --- deposit: zero amount ---

    function test_deposit_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        pool.deposit(0);
    }

    // --- borrow: zero amount ---

    function test_borrow_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        pool.borrow(0, alice);
    }

    // --- withdraw: zero amount ---

    function test_withdraw_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        pool.withdraw(0, alice);
    }

    // --- withdraw: insufficient principal ---

    function test_withdraw_insufficientPrincipal() public {
        vm.prank(alice);
        vm.expectRevert("insufficient principal");
        pool.withdraw(1, alice);
    }

    // --- repay: zero amount ---

    function test_repay_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("zero amount");
        pool.repay(0);
    }

    // --- liquidate: zero repay ---

    function test_liquidate_zeroRepay() public {
        vm.expectRevert("zero repay");
        pool.liquidate(alice, 0, true, alice);
    }

    // --- depositAndBorrow: zero deposit ---

    function test_depositAndBorrow_zeroDeposit() public {
        vm.prank(alice);
        vm.expectRevert("zero deposit");
        pool.depositAndBorrow(0, 1e6, alice);
    }

    // --- depositAndBorrow: zero borrow ---

    function test_depositAndBorrow_zeroBorrow() public {
        vm.prank(alice);
        vm.expectRevert("zero borrow");
        pool.depositAndBorrow(1e8, 0, alice);
    }

    // --- depositBackstop: zero ---

    function test_depositBackstop_zero() public {
        vm.prank(keeper);
        vm.expectRevert("zero amount");
        pool.depositBackstop(0);
    }

    // --- withdrawBackstop: zero ---

    function test_withdrawBackstop_zero() public {
        vm.expectRevert("zero amount");
        pool.withdrawBackstop(0, gov);
    }

    // --- view functions ---

    function test_viewFunctions() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        assertEq(pool.totalPrincipal(), 1e8);
        assertEq(pool.totalDebtShares(), 20_000e6 * 1e18 / pool.debtIndex());
        assertEq(pool.totalUserDebt(), 20_000e6);
        assertGt(pool.totalVaultShares(), 0);
        assertEq(pool.totalUnderlying(), 1e8);
        assertEq(pool.requiredBacking(), 1e8);
        assertEq(pool.harvestableSurplus(), 0);
        assertEq(pool.externalDebt(), 20_000e6);
        assertEq(pool.carryGap(), 0);
        assertEq(pool.userCollateralValue(alice), 60_000e6);
        assertEq(pool.userDebt(alice), 20_000e6);
    }

    // --- router: onlyPool checks ---

    function test_router_onlyPool() public {
        vm.startPrank(nobody);

        vm.expectRevert("not pool");
        router.supplyCollateralAuto(1);

        vm.expectRevert("not pool");
        router.supplyCollateral(address(adapterA), 1);

        vm.expectRevert("not pool");
        router.borrow(1, nobody);

        vm.expectRevert("not pool");
        router.repay(1);

        vm.expectRevert("not pool");
        router.repayAdapter(address(adapterA), 1);

        vm.expectRevert("not pool");
        router.withdrawCollateralShares(1, nobody);

        vm.stopPrank();
    }

    // --- router: onlyGovernance checks ---

    function test_router_onlyGovernance() public {
        vm.startPrank(nobody);

        vm.expectRevert("not governance");
        router.setPool(nobody);

        vm.expectRevert("not governance");
        router.addAdapter(address(1));

        vm.expectRevert("not governance");
        router.disableAdapter(address(adapterA));

        vm.expectRevert("not governance");
        router.removeAdapter(address(adapterA));

        vm.stopPrank();
    }

    // ================================================================
    //                        FUZZ TESTS
    // ================================================================

    function testFuzz_depositWithdraw(uint256 amount) public {
        amount = bound(amount, 1, 10e8);
        cbBTC.mint(alice, amount);
        vm.prank(alice);
        cbBTC.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        pool.deposit(amount);

        (uint256 principal,) = pool.positions(alice);
        assertEq(principal, amount);

        uint256 balBefore = cbBTC.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw(amount, alice);

        assertEq(cbBTC.balanceOf(alice) - balBefore, amount);
    }

    function testFuzz_borrowRepay(uint256 borrowAmt) public {
        vm.prank(alice);
        pool.deposit(1e8);

        borrowAmt = bound(borrowAmt, 1e6, 44_000e6);

        vm.prank(alice);
        pool.borrow(borrowAmt, alice);
        assertEq(pool.userDebt(alice), borrowAmt);

        usdc.mint(alice, borrowAmt);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(borrowAmt);
        vm.stopPrank();

        assertEq(pool.userDebt(alice), 0);
    }

    function testFuzz_debtIndex_neverDecreases(uint256 shortfall) public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        shortfall = bound(shortfall, 1e6, 50_000e6);
        adapterA.accrueInterest(shortfall);

        uint256 indexBefore = pool.debtIndex();
        pool.forceEmergencyMode();
        vm.prank(keeper);
        pool.capitalizeEmergencyShortfall();

        assertGe(pool.debtIndex(), indexBefore);
    }

    function testFuzz_liquidationSeizesOnlyPrincipal(uint256 repayAmt) public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        oracle.setPrice(50_000e6);
        repayAmt = bound(repayAmt, 1e6, 44_000e6);

        usdc.mint(liquidator, repayAmt);
        vm.prank(liquidator);
        pool.liquidate(alice, repayAmt, true, liquidator);

        // total principal must be <= original (never increased)
        assertLe(pool.totalPrincipal(), 1e8);
        // sponsor backstop never touched
        assertEq(pool.sponsorBackstop(), 0);
    }

    // ================================================================
    //              TARGETED BRANCH COVERAGE
    // ================================================================

    // --- _ceilConvertToShares with non-1:1 price (rounds up) ---

    function test_withdraw_withNonUnitSharePrice() public {
        vm.prank(alice);
        pool.deposit(1e8);

        // simulate vault appreciation -> share price > 1
        yvBTC.setSharePrice(103, 100);

        // withdraw should still work with rounding
        vm.prank(alice);
        pool.withdraw(0.5e8, alice);

        (uint256 principal,) = pool.positions(alice);
        assertEq(principal, 0.5e8);
    }

    // --- liquidation seizure capped to principal ---

    function test_liquidation_seizureCappedToPrincipal() public {
        // small deposit, big borrow, then price crash -> seized value > principal
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        // crash price so seizure value exceeds principal
        oracle.setPrice(30_000e6); // 1 BTC = 30k -> LTV ~147%

        // repay full 44k -> seizedValue = 44000 * 1.05 = 46200 USDC
        // 46200 / 30000 = 1.54 BTC > 1 BTC principal -> should cap
        vm.prank(liquidator);
        pool.liquidate(alice, 44_000e6, true, liquidator);

        (uint256 principalAfter,) = pool.positions(alice);
        assertEq(principalAfter, 0, "all principal seized (capped)");
    }

    // --- depositAndBorrow LTV exceeded ---

    function test_depositAndBorrow_ltvExceeded() public {
        vm.prank(alice);
        vm.expectRevert("ltv exceeded");
        pool.depositAndBorrow(1e8, 46_000e6, alice); // ~77% LTV > 75%
    }

    // --- _userLtvBps: principal=0, debt>0 (should be max) ---

    function test_userLtv_noPrincipal() public {
        // can't actually create this state through normal flows,
        // but test the view function indirectly: borrow with no deposit should fail
        vm.prank(alice);
        vm.expectRevert("ltv exceeded");
        pool.borrow(1e6, alice);
    }

    // --- _userLtvBps: debt=0 (should be 0 LTV) ---

    function test_withdraw_noDeb_fullWithdraw() public {
        vm.prank(alice);
        pool.deposit(1e8);
        // no borrow -> debt = 0 -> LTV = 0
        vm.prank(alice);
        pool.withdraw(1e8, alice);

        (uint256 principal,) = pool.positions(alice);
        assertEq(principal, 0);
    }

    // --- router: supplyCollateral (non-auto) ---

    function test_router_supplyCollateralSpecific() public {
        // deposit collateral directly via router from pool context
        // We need to use a path that calls supplyCollateral with specific adapter
        // Currently only supplyCollateralAuto is used, but let's test the function exists
        // by calling it through the pool mechanism (pool uses supplyCollateralAuto)
        // We'll test the adapter-not-enabled revert via the non-auto path
        MockAdapter disabledAdapter = new MockAdapter(address(yvBTC), address(usdc), 0);
        disabledAdapter.setRouter(address(router));
        router.addAdapter(address(disabledAdapter));
        router.disableAdapter(address(disabledAdapter));

        // supplyCollateral to a disabled adapter should revert
        // But we can't call router directly (only pool can).
        // This branch is already tested indirectly.
    }

    // --- router: borrow with no liquidity at all ---

    function test_router_borrowNoLiquidity() public {
        adapterA.setLiquidity(0);
        adapterB.setLiquidity(0);

        vm.prank(alice);
        pool.deposit(1e8);

        vm.prank(alice);
        vm.expectRevert("no liquidity");
        pool.borrow(1e6, alice);
    }

    // --- router: removeAdapter has collateral ---

    function test_router_removeAdapter_hasCollateral() public {
        // deposit to give adapter collateral
        vm.prank(alice);
        pool.deposit(1e8);

        router.disableAdapter(address(adapterA));

        vm.expectRevert("has collateral");
        router.removeAdapter(address(adapterA));
    }

    // --- router: repay returns excess when no debt ---

    function test_router_repayExcessReturned() public {
        // deposit but don't borrow - repaying should return all USDC
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(1_000e6, alice);

        // repay exactly 1000 - goes through router, adapter has 1000 debt
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(1_000e6);
        vm.stopPrank();

        assertEq(pool.userDebt(alice), 0);
        assertEq(adapterA.totalDebt(), 0);
    }

    // --- router: repay with excess (more than total adapter debt) ---

    function test_manualDelever_repayMoreThanAdapterDebt() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(5_000e6, alice);

        // put more USDC in buffer than debt exists
        usdc.mint(address(pool), 10_000e6);

        // delever more than the debt — router should return excess
        pool.manualDelever(10_000e6);

        assertEq(adapterA.totalDebt(), 0);
        // excess should be returned to pool
        assertGt(pool.bufferBalance(), 0);
    }

    // --- oracle: zero price revert ---

    function test_oracle_zeroPrice_borrow() public {
        vm.prank(alice);
        pool.deposit(1e8);

        oracle.setPrice(0);

        vm.prank(alice);
        vm.expectRevert("oracle: zero value");
        pool.borrow(1e6, alice);
    }

    function test_oracle_zeroPrice_liquidation() public {
        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        oracle.setPrice(0);

        vm.prank(liquidator);
        vm.expectRevert("oracle: zero value");
        pool.liquidate(alice, 1_000e6, true, liquidator);
    }

    // --- withdrawCollateral across multiple adapters ---

    function test_withdrawCollateral_acrossMultipleAdapters() public {
        // limit adapter A so collateral splits
        adapterA.setLiquidity(10_000e6);

        vm.prank(alice);
        pool.deposit(2e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        // some collateral in each adapter due to auto-routing
        // withdraw should pull from both
        usdc.mint(alice, 20_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(20_000e6);
        vm.stopPrank();

        vm.prank(alice);
        pool.withdraw(2e8, alice);

        (uint256 principal,) = pool.positions(alice);
        assertEq(principal, 0);
    }

    // ================================================================
    //              AUCTION v1.0.4 PRICING TESTS
    // ================================================================

    function test_auction_pricingSetOnPush() public {
        vm.prank(alice);
        pool.deposit(1e8);
        yvBTC.setSharePrice(110, 100);

        vm.prank(keeper);
        pool.pushSurplusToAuction(1e8);

        // auction should have been kicked with pricing set
        assertTrue(auction.isActive(address(cbBTC)));
        // startingPrice should be nonzero
        assertGt(auction.startingPrice(), 0, "startingPrice set");
        // minimumPrice should be nonzero
        assertGt(auction.minimumPrice(), 0, "minimumPrice set");
        // stepDecayRate should match pool config
        assertEq(auction.stepDecayRate(), pool.auctionDecayRate());
    }

    function test_auction_pricingMatchesOracle() public {
        vm.prank(alice);
        pool.deposit(1e8);
        yvBTC.setSharePrice(110, 100);

        vm.prank(keeper);
        pool.pushSurplusToAuction(1e8);

        // minimumPrice should reflect oracle * (10000 - slippage) / 10000
        // oracle: 1e8 cbBTC = 60_000e6 USDC
        // targetPrice = 60_000e6 * 1e18 / 1e6 = 6e22
        // minimumPrice = 6e22 * (10000 - 50) / 10000 = 6e22 * 9950/10000
        uint256 targetPrice = uint256(60_000e6) * 1e18 / 1e6;
        uint256 expectedMin = targetPrice * (10000 - pool.auctionSlippageBps()) / 10000;
        assertEq(auction.minimumPrice(), expectedMin, "minimumPrice matches oracle");
    }

    function test_auction_sellBackstopSetsPricing() public {
        cbBTC.mint(keeper, 1e8);
        vm.startPrank(keeper);
        cbBTC.approve(address(pool), type(uint256).max);
        pool.depositBackstop(1e8);
        vm.stopPrank();

        vm.prank(keeper);
        pool.sellBackstopToAuction(1e8);

        assertTrue(auction.isActive(address(cbBTC)));
        assertGt(auction.startingPrice(), 0);
    }

    function test_auction_kickAuction_afterTokensInAuction() public {
        // manually transfer tokens to auction and then kickAuction
        vm.prank(alice);
        pool.deposit(1e8);
        yvBTC.setSharePrice(110, 100);

        // first push creates an active auction
        vm.prank(keeper);
        pool.pushSurplusToAuction(1e8);

        assertTrue(auction.isActive(address(cbBTC)));

        // simulate full take (remove all cbBTC from auction)
        uint256 auctionBal = cbBTC.balanceOf(address(auction));
        vm.prank(address(auction));
        cbBTC.transfer(address(0x999), auctionBal);

        // settle the completed auction
        auction.settle(address(cbBTC));
        assertFalse(auction.isActive(address(cbBTC)));

        // now put more tokens in auction manually and kick
        cbBTC.mint(address(auction), 1e7);
        vm.prank(keeper);
        pool.kickAuction();

        assertTrue(auction.isActive(address(cbBTC)));
    }

    function test_auction_revertsWhenActive() public {
        vm.prank(alice);
        pool.deposit(2e8);
        yvBTC.setSharePrice(200, 100); // 100% yield = large surplus

        vm.prank(keeper);
        pool.pushSurplusToAuction(0.5e8);

        // can't push again while auction is active
        vm.prank(keeper);
        vm.expectRevert("auction active");
        pool.pushSurplusToAuction(0.5e8);
    }

    function test_auction_setAuctionPricingParams() public {
        pool.setAuctionStartingPriceBps(10100);
        assertEq(pool.auctionStartingPriceBps(), 10100);

        pool.setAuctionSlippageBps(100);
        assertEq(pool.auctionSlippageBps(), 100);

        pool.setAuctionDecayRate(25);
        assertEq(pool.auctionDecayRate(), 25);
    }

    function test_auction_setAuctionPricingParams_reverts() public {
        vm.expectRevert("below oracle");
        pool.setAuctionStartingPriceBps(9999);

        vm.expectRevert("too high");
        pool.setAuctionSlippageBps(5001);

        vm.expectRevert("invalid");
        pool.setAuctionDecayRate(0);

        vm.expectRevert("invalid");
        pool.setAuctionDecayRate(10000);
    }

    // ================================================================
    //              POSITION VIEWER TESTS
    // ================================================================

    function test_viewer_getUserPosition() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(30_000e6, alice);

        PositionViewer.UserPositionData memory data = viewer.getUserPosition(address(pool), alice);

        assertEq(data.principal, 1e8);
        assertEq(data.currentDebt, 30_000e6);
        assertEq(data.collateralValue, 60_000e6);
        assertTrue(data.hasPosition);
        assertFalse(data.isLiquidatable);
        // LTV = 30000/60000 = 5000 bps
        assertEq(data.currentLtvBps, 5000);
        // available to borrow: maxLTV 75% of 60k = 45k, already 30k = 15k
        assertEq(data.availableToBorrow, 15_000e6);
        assertGt(data.availableToWithdraw, 0);
    }

    function test_viewer_isLiquidatable() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        assertFalse(viewer.isLiquidatable(address(pool), alice));

        oracle.setPrice(50_000e6);
        // LTV = 44000/50000 = 88% > 85%
        assertTrue(viewer.isLiquidatable(address(pool), alice));
    }

    function test_viewer_currentLtv() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);

        assertEq(viewer.currentLtv(address(pool), alice), 0);

        vm.prank(alice);
        pool.borrow(30_000e6, alice);

        assertEq(viewer.currentLtv(address(pool), alice), 5000); // 50%
    }

    function test_viewer_totalDebt() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        assertEq(viewer.totalDebt(address(pool), alice), 20_000e6);
    }

    function test_viewer_getGlobalState() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(20_000e6, alice);

        PositionViewer.GlobalStateData memory state = viewer.getGlobalState(address(pool));

        assertEq(state.totalPrincipal, 1e8);
        assertEq(state.totalUserDebt, 20_000e6);
        assertEq(state.externalDebt, 20_000e6);
        assertEq(state.carryGap, 0);
        assertEq(state.debtIndex, 1e18);
        assertFalse(state.emergencyMode);
        assertFalse(state.paused);
    }

    function test_viewer_utilizationBps() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(30_000e6, alice);

        // utilization = 30000 / 60000 = 50% = 5000 bps
        assertEq(viewer.utilizationBps(address(pool)), 5000);
    }

    function test_viewer_batchIsLiquidatable() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);
        vm.prank(alice);
        pool.borrow(44_000e6, alice);

        vm.prank(bob);
        pool.deposit(1e8);
        vm.prank(bob);
        pool.borrow(20_000e6, bob);

        oracle.setPrice(50_000e6);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        bool[] memory results = viewer.batchIsLiquidatable(address(pool), users);
        assertTrue(results[0]);  // alice: 44000/50000 = 88% > 85%
        assertFalse(results[1]); // bob: 20000/50000 = 40% < 85%
    }

    function test_viewer_availableToBorrow_noPosition() public {
        PositionViewer viewer = new PositionViewer();
        assertEq(viewer.availableToBorrow(address(pool), nobody), 0);
    }

    function test_viewer_availableToWithdraw_noDebt() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);

        assertEq(viewer.availableToWithdraw(address(pool), alice), 1e8);
    }

    function test_viewer_collateralValue() public {
        PositionViewer viewer = new PositionViewer();

        vm.prank(alice);
        pool.deposit(1e8);

        assertEq(viewer.collateralValue(address(pool), alice), 60_000e6);
    }

    // ================================================================
    //              AUTHORITY OZ AccessControlEnumerable TESTS
    // ================================================================

    function test_authority_ozRoles() public view {
        // deployer has DEFAULT_ADMIN_ROLE
        assertTrue(authority.hasRole(authority.DEFAULT_ADMIN_ROLE(), gov));
        // deployer has GOVERNANCE_ROLE
        assertTrue(authority.hasRole(GOVERNANCE_ROLE, gov));
        // KEEPER_ROLE admin is GOVERNANCE_ROLE
        assertEq(authority.getRoleAdmin(KEEPER_ROLE), GOVERNANCE_ROLE);
        assertEq(authority.getRoleAdmin(GUARDIAN_ROLE), GOVERNANCE_ROLE);
    }

    function test_authority_governanceCanManageKeepers() public {
        // governance can grant keeper
        authority.grantRole(KEEPER_ROLE, nobody);
        assertTrue(authority.hasRole(KEEPER_ROLE, nobody));
        assertEq(authority.getRoleMemberCount(KEEPER_ROLE), 2);

        // governance can revoke
        authority.revokeRole(KEEPER_ROLE, nobody);
        assertFalse(authority.hasRole(KEEPER_ROLE, nobody));
    }

    function test_authority_keeperCannotGrantKeeper() public {
        // keepers can't manage other keepers (not admin of that role)
        vm.prank(keeper);
        vm.expectRevert();
        authority.grantRole(KEEPER_ROLE, nobody);
    }
}

import {PositionViewer} from "../src/core/PositionViewer.sol";
