# Gemach — Generic Fixed-Debt Borrowing Pool

A non-upgradeable, reserve-backed, yield-subsidized borrowing protocol. Users deposit collateral (e.g. **cbBTC**, **WETH**), borrow debt tokens (e.g. **USDC**, **aUSD**), and their debt stays flat in normal operation. All yield from the ERC-4626 vault collateral is socialized to the protocol reserve system.

## Architecture

```
User ─── deposit collateral ──▶ GemachPool ──▶ ERC-4626 Yield Vault
                                     │                     │
                                     │              AdapterRouter
                                     │               /         \
                                     ▼           MorphoAdapter  EulerAdapter
                               borrow debt ◀── lowest-cost first
                               repay  debt ──▶ highest-cost first
```

### Key Design Decisions

- **Generic pair pool** — one contract per collateral/debt pair, works with any ERC-20 pair
- **Exact principal accounting** — user balances tracked in base collateral units, not vault shares
- **Flat debt model** — `debtIndex` stays at 1e18 in normal mode; users never accrue interest except in Emergency Mode
- **Yield belongs to protocol** — surplus above user principal + sponsor backstop is harvested, auctioned for debt tokens, and routed to the buffer
- **Adapter-based backend** — core pool and router are market-agnostic; Morpho and Euler adapters isolate backend specifics
- **OpenZeppelin utilities** — uses OZ `IERC20`/`SafeERC20`, `ReentrancyGuard`, and `EnumerableSet`

## Contract Overview

| Contract | Purpose |
|---|---|
| `Authority.sol` | Central role registry (OZ EnumerableSet). Roles: GOVERNANCE, KEEPER, GUARDIAN |
| `GemachPool.sol` | Main pool — deposits, borrows, repays, withdrawals, liquidations, auction integration, emergency mode, pause |
| `AdapterRouter.sol` | Routes borrows (lowest rate first) and repayments (highest rate first) across enabled adapters |
| `MorphoAdapter.sol` | Thin wrapper for Morpho Blue market |
| `EulerAdapter.sol` | Thin wrapper for Euler V2 vault pair |

### Helpers

| Contract | Purpose |
|---|---|
| `Auth.sol` | Mixin providing `onlyGovernance`, `onlyKeeper`, `onlyGuardian` modifiers |

## Supported Pairs (Examples)

| Collateral | Debt Token | Yield Vault |
|---|---|---|
| cbBTC | USDC | yvBTC (Yearn) |
| WETH | USDC | yvETH (Yearn) |
| cbBTC | aUSD | yvBTC (Yearn) |

Each pair gets its own `GemachPool` + `AdapterRouter` deployment.

## User Flows

### Deposit
`deposit(amount)` — transfers collateral from user, deposits into yield vault, routes vault shares to adapter as collateral, records exact principal.

### Borrow
`borrow(amount, receiver)` — mints debt shares, enforces max LTV, routes borrow through adapter router to lowest-cost backend.

### Repay
`repay(amount)` / `repayFor(user, amount)` — pulls debt tokens, routes repayment to highest-cost adapter, burns debt shares.

### Withdraw
`withdraw(amount, receiver)` — checks LTV, decrements principal, pulls vault shares from router, redeems exact collateral from yield vault.

### Liquidate
`liquidate(user, repayAmount, receiveCollateral, receiver)` — permissionless; requires user LTV > liquidation threshold. Liquidator repays debt, seizes user principal (with bonus). Never touches protocol surplus or sponsor backstop.

## Reserve System

1. **Yield** — vault shares appreciate over time; surplus above `totalPrincipal + sponsorBackstop` is protocol-owned
2. **Auction** — surplus is redeemed to base collateral and sold for debt tokens via the Yearn V3 Dutch auction system
3. **Buffer** — auction proceeds accumulate as idle debt tokens in the pool
4. **Fees** — governance can take fees only when buffer exceeds a target percentage of total user debt
5. **Sponsor backstop** — protocol/treasury can deposit collateral as additional backing; consumed before emergency mode
6. **Emergency mode** — when buffer and backstop are exhausted, uncovered carry is socialized across borrowers via `debtIndex` increase

## Admin Operations

### Keeper Functions
- `pushSurplusToAuction(maxAmount)` — harvest yield surplus for auction
- `sellBackstopToAuction(maxAmount)` — sell sponsor backstop
- `kickAuction()` — start auction
- `routeIdleDebtTokens(maxAmount)` — repay external debt with buffer
- `syncAndMaybeEnterEmergency()` — check emergency conditions
- `depositBuffer(amount)` — top up buffer
- `depositBackstop(amount)` — deposit sponsor backstop
- `capitalizeEmergencyShortfall()` — socialize uncovered carry in emergency mode

### Governance Functions
All keeper functions, plus:
- `pause()` / `unpause()` — circuit breaker (guardian can also pause)
- `forceEmergencyMode()` / `clearEmergencyMode()` — manual emergency control
- `takeProtocolFee(amount)` — extract fees from buffer excess
- `manualRepayAdapter(adapter, amount)` — targeted delever
- `manualDelever(amount)` — emergency delever with buffer
- `withdrawBackstop(amount, receiver)` — withdraw sponsor backstop (safety checks)
- `sweepNonCoreToken(token, to, amount)` — rescue accidentally sent tokens (never core assets)
- Parameter setters for LTV, liquidation bonus, fees, oracle, router, auction config

### Pause Behavior
When paused, **blocked**: deposit, borrow, withdraw, backstop withdrawal, fee taking.
When paused, **allowed**: repay, liquidate, auction operations, buffer top-up, backstop deposit, delever, emergency functions.

## Configuration Parameters

| Parameter | Description |
|---|---|
| `maxBorrowLtvBps` | Maximum LTV for new borrows (basis points) |
| `liquidationLtvBps` | LTV threshold for liquidation |
| `liquidationBonusBps` | Liquidator bonus on seized collateral |
| `feeActivationBufferBps` | Buffer must be this % of total debt before fees activate |
| `protocolFeeBps` | Max fee as % of buffer excess |
| `minAuctionLot` | Minimum collateral amount per auction lot |

## Building & Testing

```bash
forge build
forge test -vv
forge coverage
```

## Test Coverage (protocol contracts)

| Contract | Lines | Branches | Functions |
|---|---|---|---|
| Authority.sol | 100% | 100% | 100% |
| Auth.sol | 100% | 100% | 100% |
| GemachPool.sol | 99.6% | 96.3% | 100% |
| AdapterRouter.sol | 96.6% | 85.3% | 100% |

## Invariants

1. `principal` changes only on deposit, withdraw, or liquidation
2. Yield never reduces user principal or user debt
3. User debt stays flat in normal mode; only increases in emergency mode
4. `debtIndex` never decreases
5. Sponsor backstop is consumed before emergency user accrual
6. Liquidators seize only user principal, never protocol surplus
7. No state-changing path loops over users
8. Repay, liquidate, and delever remain callable while paused
