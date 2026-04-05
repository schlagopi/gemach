# Gemach — Generic Fixed-Debt Borrowing Pool

## Project
Non-upgradeable Solidity protocol (Foundry). Generic fixed-debt, reserve-backed, yield-subsidized borrowing pool. Works with any collateral/debt pair (cbBTC/USDC, WETH/USDC, etc.). Users deposit collateral, borrow debt tokens. Debt stays flat in normal mode. Yield socialized to protocol reserve.

## Tech Stack
- Solidity ^0.8.24 (compiles with 0.8.33)
- Foundry (forge 1.5.1)
- OpenZeppelin v5.6.1 (IERC20, SafeERC20, ReentrancyGuard, EnumerableSet)
- Target: Ethereum mainnet

## Codebase Conventions
- `require("message")` only in protocol contracts
- OZ ReentrancyGuard and SafeERC20 (replaced custom implementations)
- Central Authority contract for all role checks
- No proxies, no upgrades
- No user loops; small bounded loops over adapters only (max 8)
- All user accounting in base collateral units, not vault shares
- Generic naming: `collateralToken`, `debtToken`, `yieldVault` (not pair-specific)

## Key Directories
- `src/access/` — Authority (role registry)
- `src/core/` — GemachPool, AdapterRouter
- `src/adapters/` — IMarketAdapter, MorphoAdapter, EulerAdapter
- `src/interfaces/` — IYearnVault4626, IYearnAuction, IPriceOracle
- `src/utils/` — Auth
- `test/mocks/` — MockERC20, MockYearnVault4626, MockYearnAuction, MockOracle, MockAdapter
- `test/` — Full test suite (114 tests, 4 fuzz)

## Build & Test
```bash
forge build
forge test -vv
forge coverage
```
