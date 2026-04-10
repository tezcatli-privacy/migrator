# Tezcatli Migrator

This project is the first CoFHE-based Tezcatli prototype: a wallet migrator that moves public ERC-20 balances into confidential balances using a stealth-style intake flow and an FHE-wrapped destination token.

The MVP keeps the contract surface intentionally small:

- `MockUSDC.sol`: a 6-decimal ERC-20 used for local testing
- `MockDustToken.sol`: an 18-decimal ERC-20 used to exercise dust-swap migration paths
- `TezcatliStealthRegistry.sol`: registers stealth meta-addresses
- `TezcatliStealthAnnouncer.sol`: announces and optionally transfers public funds to stealth addresses
- `TezcatliWrappedToken.sol`: wraps an ERC-20 into confidential `FHERC20` balances
- `TezcatliMigrator.sol`: sweeps approved funds from one or many stealth addresses and lands them directly in confidential wrapped balances
- `TezcatliDustSwap.sol`: converts supported dust tokens into settlement USDC before shielding
- `TezcatliSmartAccount.sol`: programmable destination account with owner calls, relayed `executeBySig` / `executeBatchBySig`, and ERC-1271
- `TezcatliSmartAccountFactory.sol`: deterministic CREATE2 factory for smart-account deployment
- `TezcatliEntryPointMock.sol`: minimal local EntryPoint for ERC-4337-style tests
- `Tezcatli4337Account.sol`: simple account-abstraction smart account with `validateUserOp` and ERC-1271
- `Tezcatli4337AccountFactory.sol`: deterministic factory for the 4337 account
- `TezcatliPaymaster.sol`: target-restricted ERC-20 fee paymaster for sponsored user operations
- `TezcatliConfidentialVault.sol`: confidential deposit/withdraw vault using callback-based FHERC20 deposits
- `TezcatliConfidentialVaultFactory.sol`: one-vault-per-asset factory for confidential vault deployment
- `TezcatliVaultCoordinator.sol`: operator-controlled coordinator for strategy deploy/redeem actions
- `TezcatliStrategyAdapterERC4626.sol`: ERC-4626 adapter that isolates strategy interactions from vault logic
- `TezcatliVaultFeeModel.sol`: bonding-curve fee model (5.00% -> 0.50%) across 3/6/12/18 month options
- `TezcatliGmxPrivacyWrapper.sol`: stealth-signature relay wrapper for GMX `ExchangeRouter.multicall(...)` order submission
- `MockGmxExchangeRouter.sol`: local mock used to test GMX-style multicall order routing

## Migration Model

The step-1 migration flow is:

1. A user registers a stealth meta-address
2. Public funds are sent to a one-time stealth address
3. The stealth address signs a sweep authorization
4. `TezcatliMigrator` pulls the public ERC-20
5. `TezcatliWrappedToken` shields the public amount directly to the final recipient address
6. That recipient can be an EOA or a Tezcatli smart account
7. A smart-account owner can later move confidential balances out through `execute(...)`

This breaks the simple `public wallet -> visible destination` pattern and lands funds in confidential onchain state.

The migrator now supports two ingestion paths:

- direct supported-token migration: `sweepAndMigrate(...)`
- dust-token conversion into settlement USDC: `sweepSwapAndMigrate(...)`

The migrator now supports both:

- single-item migration via `sweepAndMigrate(...)`
- simple batching via `sweepAndMigrateBatch(...)`

In the batch path, each stealth address still signs its own authorization. The batch just executes multiple signed migrations in one contract call.

## Scope of this MVP

This first pass is intentionally conservative:

- the migration path solves source-to-destination linkage first
- the recipient lands in an encrypted balance model immediately after migration
- the destination can already be a programmable smart account
- the ingress amount is still visible during the public ERC-20 sweep
- dust swaps use a simple whitelisted rate-based contract, not a live DEX router

That last point matters. A secure migrator should not accept an encrypted amount it cannot verify against the public sweep amount. Full amount privacy during migration needs a batching or aggregation layer on top of the stealth intake, which is a later step.

The confidential vault + strategy orchestration pass is now included:

- users deposit with `confidentialTransferAndCall(...)` into `TezcatliConfidentialVault`
- vault shares are tracked as encrypted balances per account
- withdrawals are full-exit requests (no amount parameter) and paid out as confidential token transfers
- vault includes `pause/unpause` and emergency recovery for non-asset ERC-20 tokens
- `TezcatliVaultCoordinator` + `TezcatliStrategyAdapterERC4626` route funds into ERC-4626 strategies and back
- strategy adapters can be configured per vault with risk buckets (`low`, `medium`, `high`) and allocation caps in bps
- vault fee model supports 4 lock options (3/6/12/18 months) with a time-decay fee curve from 5.00% to floor fee
- withdrawals are gated by a minimum 7-day delay from latest deposit activity (MVP liquidity constraint)
- fee is charged only on realized yield in the opt-in lock flow; principal is not charged

Current vault limitation:

- lock configuration is user-level (single active lock option and start timestamp per account), not tranche-level per deposit
- minimum withdrawal delay is currently user-level and resets on each new deposit
- when lock-fee mode is used, strategy positions should be redeemed before user withdrawals so payout liquidity is settled on-vault
- allocation caps are enforced against the currently managed strategy set (not full vault TVL including idle confidential liquidity)

## CoFHE Encrypted Input Account

When generating encrypted inputs for post-migration `confidentialTransfer(...)`, set:

- `account = caller address`

For a direct transfer, that means the wallet calling `confidentialTransfer(...)`.
For an account-abstraction flow, that means the smart account address.

## Requirements

- Node.js 18+
- pnpm

## Install

```bash
pnpm install
```

## Commands

### Local development

```bash
pnpm compile
pnpm test
```

### Deploy the migrator stack

```bash
pnpm task:deploy
```

### Run the demo migration task

```bash
pnpm task:migrate-demo
```

The demo task:

- deploys the contracts
- mints public `MockUSDC`
- deploys a deterministic smart account
- signs a stealth sweep authorization
- sweeps and migrates into the smart account
- performs a smart-account outbound confidential transfer with `@cofhe/sdk`
- decrypts the recipient balance to verify the flow

### Run the dust-swap demo task

```bash
pnpm task:dust-swap-demo
```

The dust-swap demo task:

- mints mock dust tokens to a stealth signer
- signs a dust-swap migration authorization
- swaps dust into settlement USDC through `TezcatliDustSwap`
- shields the settlement amount into a confidential recipient balance
- decrypts the recipient balance to verify the flow

### Run the paymaster demo task

```bash
pnpm task:paymaster-demo
```

The paymaster demo task:

- migrates funds from a stealth signer into a 4337 smart account
- prepares a sponsored user operation through `TezcatliPaymaster`
- executes a confidential transfer from the smart account via `TezcatliEntryPointMock`
- verifies recipient confidential balance and fee collection in USDC

### Local CoFHE network

```bash
pnpm localcofhe:start
pnpm localcofhe:deploy
pnpm localcofhe:test
```

## Test Coverage

The test suite currently covers:

- stealth meta-address registration
- public announcement plus transfer to a stealth address
- stealth sweep into a confidential wrapped balance
- dust-token swap into confidential USDC
- batch sweep from multiple stealth addresses in one call
- smart-account destination migration
- smart-account outbound confidential transfer via `execute(...)`
- 4337 paymaster sponsorship for approved targets
- paymaster rejections for unapproved targets and unapproved factories
- confidential vault deposits through token callback
- confidential vault full-exit withdrawals with a 7-day minimum delay
- vault pause controls and factory one-vault-per-asset enforcement
- strategy routing through `TezcatliVaultCoordinator` and `TezcatliStrategyAdapterERC4626`
- multi-strategy allocation cap enforcement by risk profile
- lock-option fee decay and yield-only fee charging behavior
- end-to-end paymaster-sponsored confidential transfer after migration to a 4337 account
- recipient-side decryption with `decryptForView(...)`
- post-migration confidential transfers
- unshielding confidential funds back into the public ERC-20
- permit validation
- stealth-authorized GMX multicall relay with nonce/deadline replay protection and multicall-hash integrity checks
- GMX wrapper fixed-leverage policy validation (`sizeUsd == collateralUsd * 2`) for 2x intents
- relayer execution from session smart accounts via `executeBySig` / `executeBatchBySig`

## Notes

- This repo now covers step 1 and a substantial step-2 slice. It includes a local 4337 test surface (`TezcatliEntryPointMock`, `Tezcatli4337Account`, `TezcatliPaymaster`) plus confidential vault strategy orchestration and allocation controls.
- `TezcatliPaymaster` is intentionally strict for safety and simplicity:
- it only sponsors `execute(address,uint256,bytes)` calls
- it requires an approved target list
- it enforces factory allowlisting for `initCode` deployments
- Dust swaps are deliberately modeled as a controlled onchain converter for MVP purposes. Replacing that with a DEX/aggregator route is a later hardening step.
- NFTs are intentionally out of scope for this first pass.
- The wrapped token uses `fhenix-confidential-contracts` to keep the confidentiality layer simple and close to ecosystem conventions.
- The GMX wrapper is an MVP relay primitive: it protects signer identity with stealth authorization + relayer execution, but calldata to the GMX router is still public onchain.
- The GMX wrapper enforces a 2x leverage policy at authorization level (`sizeUsd = collateralUsd * 2`). For hard onchain enforcement against malformed GMX payloads, add calldata decoding/validation for `createOrder(...)` fields in a next iteration.
- Privacy options for GMX-style trading in this repo:
- baseline relay: use `TezcatliGmxPrivacyWrapper` with stealth-signed authorization (single shared wrapper account on GMX)
- account-per-session: deploy one `TezcatliSmartAccount` per trading session via CREATE2 salt and execute through `executeBySig`
- metadata hardening: route with relayers and rotate salts / smart accounts frequently to reduce linkage
- stronger anonymity set: batch users behind coordinated relayer windows (timing obfuscation)
- network privacy (next step): private RPC / proxy transport so node operators cannot trivially correlate source IP with account activity
