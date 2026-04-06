# Gemach Protocol Audit Findings

Generated 2026-04-06. Findings H-1, H-2, H-4 have been fixed. Remaining findings below.

---

## HIGH SEVERITY

### H-3: Operator Can Steal User Funds via Borrow + Withdraw

- **Severity**: High
- **Location**: `src/core/GemachPool.sol` — `borrowFrom()` and `withdrawFrom()`
- **Description**: An operator approved by a user can call both `borrowFrom()` (sending debt tokens to any `receiver`) and `withdrawFrom()` (sending collateral to any `receiver`). Together, an operator can:
  1. Borrow up to `maxBorrowLtvBps` worth of debt tokens to themselves
  2. Withdraw remaining collateral to themselves
  
  While this is technically "authorized" by the user, the operator pattern provides no granularity. A user who approves an operator for a specific integration (e.g., a strategy contract) is granting blanket permission to drain their entire position. There is no way to approve an operator for "borrow only" or "withdraw only" or with amount limits.
- **Impact**: A compromised or malicious operator contract can steal the entirety of a user's collateral and borrow their maximum debt. This is a trust assumption that should be clearly documented, but the lack of scoping makes it unusually dangerous.
- **Recommendation**: Consider implementing scoped approvals (e.g., separate `borrowOperator` and `withdrawOperator` mappings, or EIP-7702-style permissions with limits). At minimum, document the full-access nature of operator approval prominently and consider adding an event for operator changes for off-chain monitoring.

---

## MEDIUM SEVERITY

### M-1: `pushSurplusToAuction` Redeems Entire Pool Vault Balance

- **Severity**: Medium
- **Location**: `src/core/GemachPool.sol:244-245` and `sellBackstopToAuction:261`
- **Description**: In `pushSurplusToAuction()`, after withdrawing `sharesNeeded` from the router, the function redeems `IERC20(YIELD_VAULT).balanceOf(address(this))` — the pool's entire yield vault balance. If any vault shares are temporarily held by the pool (e.g., from a direct transfer or edge case), those extra shares would also be redeemed and sent to the auction. The same pattern appears in `sellBackstopToAuction()`.
- **Impact**: Could result in redeeming more collateral than intended, potentially causing later vault share operations to fail due to insufficient balance, or leaking extra funds into the auction.
- **Recommendation**: Redeem only `sharesNeeded` instead of the entire balance:
  ```solidity
  uint256 redeemed = IYearnVault4626(YIELD_VAULT).redeem(sharesNeeded, address(this), address(this));
  ```

### M-2: Liquidation Can Be Grief-Blocked by Front-Running

- **Severity**: Medium
- **Location**: `src/core/GemachPool.sol:194-227`
- **Description**: A malicious user (or MEV bot) can front-run a liquidation transaction by repaying a dust amount, which reduces `debtShares` and may push the position's LTV just below `liquidationLtvBps`, causing the liquidator's transaction to revert. This is a standard griefing vector.
- **Impact**: Liquidators waste gas, and unhealthy positions can oscillate around the liquidation threshold. In volatile markets, this delays necessary liquidations.
- **Recommendation**: Consider allowing partial liquidation even if it brings the position below the threshold, or implement a grace period.

### M-3: No Validation That `liquidationLtvBps > maxBorrowLtvBps`

- **Severity**: Medium
- **Location**: `src/core/GemachPool.sol` — `setMaxBorrowLtvBps()` and `setLiquidationLtvBps()`
- **Description**: The two LTV setters are independent with no cross-validation. If governance sets `liquidationLtvBps < maxBorrowLtvBps`, any user who borrows up to the max LTV would be instantly liquidatable.
- **Impact**: All active borrowing positions could become immediately liquidatable.
- **Recommendation**: Add cross-validation:
  ```solidity
  function setMaxBorrowLtvBps(uint256 _bps) external onlyGovernance {
      require(_bps <= 9500, "too high");
      require(liquidationLtvBps == 0 || _bps < liquidationLtvBps, "must be below liq ltv");
      maxBorrowLtvBps = _bps;
  }
  ```

### M-4: Router `repay()` Excess Tokens Stuck

- **Severity**: Medium
- **Location**: `src/core/AdapterRouter.sol:127-140`
- **Description**: The `repay()` function transfers the full `amount` from the caller, then iterates adapters repaying as much as possible. If `remaining > 0` after the loop (because adapters have less debt than the repay amount), the surplus debt tokens remain stuck in the router with no recovery path.
- **Impact**: Debt tokens can become permanently stuck in the router contract.
- **Recommendation**: Either revert if `remaining > 0`, or add a sweep function to the router for stuck tokens.

### M-5: Zero-Principal Positions Create Permanent Bad Debt

- **Severity**: Medium
- **Location**: `src/core/GemachPool.sol` — `_userLtvBps()` and `liquidate()`
- **Description**: When `pos.principal == 0` and the user has debt, `_userLtvBps` returns `type(uint256).max`. In `liquidate()`, `seizedCollateral` is capped at `pos.principal` (which is 0), so the liquidator repays debt but seizes nothing. No one will liquidate zero-principal positions since there's nothing to seize, leaving bad debt permanently.
- **Impact**: Bad debt accumulates with no economic incentive to clear it.
- **Recommendation**: Implement a governance function to write off bad debt positions, or allow anyone to clear zero-principal positions.

### M-6: Emergency Mode Entry Conditions Too Strict

- **Severity**: Medium
- **Location**: `src/core/GemachPool.sol` — `syncAndMaybeEnterEmergency()`
- **Description**: Auto-entry requires `protocolBuffer() == 0 && sponsorBackstop == 0 && externalDebt() > totalUserDebt()`. Even 1 wei of `sponsorBackstop` prevents auto-entry regardless of carry gap size. The backstop is a bookkeeping variable that may not reflect actual available funds.
- **Impact**: System may fail to enter emergency mode when it should.
- **Recommendation**: Consider relaxing: if carry gap exceeds backstop value, allow entry.

### M-7: `sweepNonCoreToken` Scope

- **Severity**: Medium
- **Location**: `src/core/GemachPool.sol` — `sweepNonCoreToken()`
- **Description**: Blocks sweeping `COLLATERAL_TOKEN`, `DEBT_TOKEN`, and `YIELD_VAULT`, but doesn't block tokens relevant to adapter operations or auction proceeds that arrive as non-core tokens.
- **Impact**: Governance could extract value from unexpected token arrivals.
- **Recommendation**: Document clearly what tokens may transit through the pool.

---

## LOW SEVERITY

### L-1: No Events Emitted

- **Severity**: Low
- **Location**: Throughout `src/core/GemachPool.sol`
- **Description**: The contract emits no events. All state changes (deposits, borrows, repays, withdrawals, liquidations, emergency mode changes, parameter updates, operator approvals) are silent.
- **Impact**: No ability to track protocol activity off-chain. Debugging, dashboards, and security monitoring impaired.
- **Recommendation**: Add events for all state-changing functions.

### L-2: No Minimum Collateral/Debt Amounts

- **Severity**: Low
- **Location**: `src/core/GemachPool.sol` — `_deposit()` and `_borrow()`
- **Description**: Users can deposit 1 wei of collateral and borrow 1 wei of debt. Dust positions increase storage costs and can become unliquidatable.
- **Impact**: Gas griefing through mass dust positions.
- **Recommendation**: Enforce minimum deposit and borrow amounts.

### L-3: `setRouter` Doesn't Revoke Old Router Approval

- **Severity**: Low
- **Location**: `src/core/GemachPool.sol` — `setRouter()`
- **Description**: Changing the router approves the new one but doesn't revoke the old router's `type(uint256).max` approval.
- **Impact**: Compromised old router can still pull tokens.
- **Recommendation**: Revoke old approvals before setting new ones.

### L-4: Disabled Adapter Repay Behavior Undocumented

- **Severity**: Low
- **Location**: `src/core/AdapterRouter.sol` — `repay()` and `withdrawCollateralShares()`
- **Description**: These functions operate on all adapters including disabled ones. This is correct for wind-down but undocumented.
- **Recommendation**: Add NatSpec documenting the intentional behavior.

### L-5: `clearEmergencyMode` Lacks Buffer Margin

- **Severity**: Low
- **Location**: `src/core/GemachPool.sol` — `clearEmergencyMode()`
- **Description**: Can be cleared the same block as capitalization. Interest accrues immediately after, reopening the gap.
- **Recommendation**: Require a small buffer margin when clearing.

### L-6: First Depositor Protections

- **Severity**: Low
- **Location**: `src/core/GemachPool.sol` — `_deposit()`
- **Description**: No special protections for the first depositor. Relies on the Yearn vault being safe from share inflation attacks.
- **Recommendation**: Ensure the Yearn vault has inflation mitigations.

---

## INFORMATIONAL

### I-1: Centralization Risks

Governance can change oracle, router, authority instantly with no timelock. A compromised governance key can steal all funds by pointing to a malicious oracle or router. **Recommendation**: Timelock for sensitive changes, multi-sig for governance.

### I-2: `kickAuction()` Lacks `nonReentrant`

Makes external calls without reentrancy protection. Low risk since `onlyKeeper` and no pool accounting changes, but defense-in-depth suggests adding it.

### I-3: Unchecked Return Values

Pool ignores return values from `router.borrow()` and `router.repay()`. The router guarantees amounts via `require`, but explicit checks add safety.

### I-4: Redundant Oracle Calls in Positions Library

`_availableToWithdraw` calls the oracle multiple times. Cache the result for gas savings.

### I-5: `sponsorBackstop` Tracks Nominal Amounts

Tracks collateral units deposited, not actual redeemable vault value. If the vault loses value, the backstop provides less protection than `sponsorBackstop` suggests.

### I-6: `setOperator` Emits No Event

Operator approval changes are silent. Off-chain systems cannot track approvals.
