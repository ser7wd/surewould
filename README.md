# Surewould — Robinhood Chain Launchpad

Pump.fun-style token launcher: anyone calls `launch()` to create a token with zero
presale, trading starts immediately on a constant-product bonding curve, and once
enough real ETH is raised the token auto-migrates to a real Uniswap V2 pool with the
LP tokens burned (so nobody, including you, can pull that liquidity later).

## Files
- `src/LaunchToken.sol` — plain ERC20, fixed supply, no admin functions
- `src/BondingCurve.sol` — the pricing engine: buy/sell against virtual reserves, migration trigger
- `src/LaunchpadFactory.sol` — deploys token+curve pairs, executes the Uniswap migration
- `test/LaunchpadFactory.t.sol` — 21 Foundry tests covering launch, buy/sell math, fees, slippage, and full migration
- `test/mocks/MockUniswapV2Router.sol` — minimal router stand-in used only for testing

## How the math works
Price follows `x * y = k` using **virtual** reserves (`VIRTUAL_ETH_RESERVES`,
`VIRTUAL_TOKEN_RESERVES`) so the curve has a sane starting price without needing real
liquidity seeded up front — same trick pump.fun uses. **Real** reserves (`realEthReserves`,
`realTokenReserves`) track what's actually been collected, and that's what determines
migration and what gets paired into the eventual Uniswap pool.

Every buy/sell takes a 1% fee (`FEE_BPS`) to `feeRecipient` — that's your monetization.

## Tests

21 Foundry tests, including a fuzz test, all passing — verified in this session against
a real forge build + a mock Uniswap router, not just written and hoped for:

```bash
forge test -vv
```

Writing and running these caught two real bugs that are now fixed in the contracts:

1. **Token supply could run dry before migration.** The original constants let the
   curve's 800M token allocation fully sell out at ~8.79 ETH raised, but migration
   wasn't triggered until 12 ETH — so a big buy near the threshold would revert
   instead of migrating. `MIGRATION_THRESHOLD` is now 8 ETH, leaving margin.
2. **A 1-wei rounding gap on sells.** Selling back tokens immediately after buying
   them could compute an ETH payout 1 wei above what the curve actually held,
   reverting a legitimate sell. `sell()` now clamps its payout to `realEthReserves`.

If you change `VIRTUAL_ETH_RESERVES`, `VIRTUAL_TOKEN_RESERVES`, `CURVE_ALLOCATION`,
or `MIGRATION_THRESHOLD`, rerun the fuzz test (`forge test --fuzz-runs 2000`) before
trusting the new numbers — they're load-bearing on each other, not independent knobs.

## Before you deploy anything real, tune these in `LaunchpadFactory.sol`
- `VIRTUAL_ETH_RESERVES` (3 ether) — sets the starting price curve steepness
- `MIGRATION_THRESHOLD` (8 ether) — real ETH raised before graduating to Uniswap
- `CURVE_ALLOCATION` / `TOTAL_SUPPLY` split — how many tokens are sellable vs. reserved for LP

Robinhood Chain gas is sub-cent and ETH is the gas token, so these ETH-denominated
thresholds need real thought — 8 ETH to graduate might be way too high or low
depending on what kind of launches you expect. Model this before mainnet use.

## Confirmed addresses (from Uniswap's official deployments page, July 2026)
- **Robinhood Chain mainnet (4663) Uniswap V2 Router02:** `0x89e5db8b5aa49aa85ac63f691524311aeb649eba`
- **Robinhood Chain mainnet V2 Factory:** `0x8bceaa40b9acdfaedf85adf4ff01f5ad6517937f`
- **Testnet (46630): no Uniswap deployment listed** — use `MockUniswapV2Router` as the
  migration target on testnet (the deploy script handles this automatically).

Re-verify against https://developers.uniswap.org/docs/protocols/v2/deployments before
any mainnet deploy — addresses in a README can go stale.

## What you still need before this is a real product
1. **Independent security review.** This is a well-tested first draft, not an audited
   contract. Before real money touches it: get a second pair of eyes (human or a tool
   like Slither), add real slippage bounds in `completeMigration` (currently `0, 0` —
   fine for testing, not for mainnet), and consider a max-buy-per-tx cap to slow down
   sniping bots.
2. **Frontend** — done: `index.html` (wallet connect, launch, trade, graduation progress).
3. **Indexer** — you already have the start of this in Prospector; extend it to watch
   `TokenLaunched` and `Trade` events for a live feed.

## Deploying (once you have a router address)

```bash
# from Robinhood Chain's own docs pattern (Foundry)
curl -L https://foundry.paradigm.xyz | bash
foundryup

export PRIVATE_KEY=0x<throwaway_key_funded_with_ETH>
export RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com   # or testnet: https://rpc.testnet.chain.robinhood.com

forge create src/LaunchpadFactory.sol:LaunchpadFactory \
  --rpc-url $RH_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <UNISWAP_V2_ROUTER_ADDRESS> <YOUR_FEE_WALLET> \
  --broadcast

# then verify on Blockscout
forge verify-contract <DEPLOYED_ADDRESS> \
  src/LaunchpadFactory.sol:LaunchpadFactory \
  --chain-id 4663 \
  --rpc-url $RH_RPC_URL \
  --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api/
```

Test on testnet first (chain ID 46630, faucet at faucet.testnet.chain.robinhood.com)
before touching mainnet with real ETH.
