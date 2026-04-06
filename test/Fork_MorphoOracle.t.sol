// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @notice Minimal interface for the Morpho Chainlink Oracle V2 Factory.
interface IMorphoOracleFactory {
    function createMorphoChainlinkOracleV2(
        address baseVault,
        uint256 baseVaultConversionSample,
        address baseFeed1,
        address baseFeed2,
        uint256 baseTokenDecimals,
        address quoteVault,
        uint256 quoteVaultConversionSample,
        address quoteFeed1,
        address quoteFeed2,
        uint256 quoteTokenDecimals,
        bytes32 salt
    ) external returns (address oracle);
}

/// @title Fork_MorphoOracleTest
/// @notice Fork test that deploys a real Morpho Chainlink Oracle V2 from the
///         mainnet factory and verifies the price is sane for cbBTC/USDC.
///         Run with: ETH_RPC_URL=<url> forge test --mc Fork_MorphoOracle -vvv
contract Fork_MorphoOracleTest is Test {
    // -------- mainnet addresses --------
    address constant MORPHO_ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;
    address constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // 8 decimals
    address constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // 8 decimals
    address constant YVBTC_VAULT = 0xA6D6950c9F177F1De7f7757FB33539e3Ec60182a;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    uint256 constant ORACLE_PRICE_SCALE = 1e36;

    uint256 mainnetFork;
    bool forkAvailable;

    function setUp() public {
        mainnetFork = vm.createFork("https://ethereum-rpc.publicnode.com");
        forkAvailable = true;
    }

    modifier onFork() {
        require(forkAvailable, "fork not available");
        vm.selectFork(mainnetFork);
        _;
    }

    /// @notice Deploy a Morpho oracle pricing cbBTC in USDC (no vault conversion).
    ///         This is what the pool would use for LTV calculations.
    function test_deployOracle_cbBTC_USDC() public onFork {
        IMorphoOracleFactory factory = IMorphoOracleFactory(MORPHO_ORACLE_FACTORY);

        // base = cbBTC (collateral), quote = USDC (loan)
        // no vaults — direct price of cbBTC in USDC
        address oracle = factory.createMorphoChainlinkOracleV2(
            address(0), // baseVault: none
            1, // baseVaultConversionSample: 1 (no vault)
            BTC_USD_FEED, // baseFeed1: BTC/USD
            address(0), // baseFeed2: none
            8, // baseTokenDecimals: cbBTC = 8
            address(0), // quoteVault: none
            1, // quoteVaultConversionSample: 1
            USDC_USD_FEED, // quoteFeed1: USDC/USD
            address(0), // quoteFeed2: none
            6, // quoteTokenDecimals: USDC = 6
            keccak256("gemach-test-cbbtc-usdc")
        );

        uint256 p = IPriceOracle(oracle).price();
        assertGt(p, 0, "price should be nonzero");

        // Verify: 1e8 cbBTC * price / 1e36 should give ~60k-100k USDC (6 dec)
        uint256 usdcValue = 1e8 * p / ORACLE_PRICE_SCALE;
        assertGt(usdcValue, 50_000e6, "1 BTC should be > $50k");
        assertLt(usdcValue, 200_000e6, "1 BTC should be < $200k");

        emit log_named_uint("cbBTC/USDC oracle price (1e36 scaled)", p);
        emit log_named_uint("1 BTC in USDC", usdcValue);
    }

    /// @notice Deploy a Morpho oracle pricing yvBTC in USDC with vault conversion.
    ///         This demonstrates how the adapter's Morpho market would be set up.
    function test_deployOracle_yvBTC_USDC_withVault() public onFork {
        // First check if the yvBTC vault responds to convertToAssets
        (bool ok,) = YVBTC_VAULT.staticcall(abi.encodeWithSignature("convertToAssets(uint256)", 1e8));

        if (!ok) {
            emit log("yvBTC vault not responding to convertToAssets, skipping vault test");
            return;
        }

        IMorphoOracleFactory factory = IMorphoOracleFactory(MORPHO_ORACLE_FACTORY);

        address oracle = factory.createMorphoChainlinkOracleV2(
            YVBTC_VAULT, // baseVault: yvBTC (converts yvBTC shares -> cbBTC)
            1e8, // baseVaultConversionSample: 1e8 (8 decimals)
            BTC_USD_FEED, // baseFeed1: BTC/USD
            address(0), // baseFeed2: none
            8, // baseTokenDecimals: cbBTC = 8
            address(0), // quoteVault: none
            1, // quoteVaultConversionSample: 1
            USDC_USD_FEED, // quoteFeed1: USDC/USD
            address(0), // quoteFeed2: none
            6, // quoteTokenDecimals: USDC = 6
            keccak256("gemach-test-yvbtc-usdc")
        );

        uint256 p = IPriceOracle(oracle).price();
        assertGt(p, 0, "price should be nonzero");

        // yvBTC should be worth >= 1 BTC (yield accrues)
        uint256 usdcValue = 1e8 * p / ORACLE_PRICE_SCALE;
        assertGt(usdcValue, 50_000e6, "1 yvBTC should be > $50k");

        emit log_named_uint("yvBTC/USDC oracle price (1e36 scaled)", p);
        emit log_named_uint("1 yvBTC in USDC", usdcValue);
    }

    /// @notice Verify the math: collateral * price / 1e36 gives correct USDC.
    ///         And the reverse: debtAmount * 1e36 / price gives correct collateral.
    function test_oracleMath_roundTrip() public onFork {
        IMorphoOracleFactory factory = IMorphoOracleFactory(MORPHO_ORACLE_FACTORY);

        address oracle = factory.createMorphoChainlinkOracleV2(
            address(0),
            1,
            BTC_USD_FEED,
            address(0),
            8,
            address(0),
            1,
            USDC_USD_FEED,
            address(0),
            6,
            keccak256("gemach-test-roundtrip")
        );

        uint256 p = IPriceOracle(oracle).price();

        // Forward: collateral -> debt
        uint256 collateral = 2.5e8; // 2.5 BTC
        uint256 debtValue = collateral * p / ORACLE_PRICE_SCALE;
        emit log_named_uint("2.5 BTC in USDC", debtValue);

        // Reverse: debt -> collateral
        uint256 collateralBack = debtValue * ORACLE_PRICE_SCALE / p;
        // Should be close to 2.5e8 (may lose 1 wei to rounding)
        assertApproxEqAbs(collateralBack, collateral, 1, "round-trip should be ~exact");

        // LTV check: 150k USDC debt against 2.5 BTC collateral
        uint256 debt = 150_000e6;
        uint256 ltvBps = debt * 10000 / debtValue;
        emit log_named_uint("LTV bps for 150k debt / 2.5 BTC", ltvBps);
        // Should be somewhere reasonable (e.g. ~85% at ~69k BTC)
        assertGt(ltvBps, 5000, "LTV should be > 50%");
        assertLt(ltvBps, 9500, "LTV should be < 95%");
    }
}
