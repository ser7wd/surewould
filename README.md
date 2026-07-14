# Robinhood Chain Launchpad — Bonding Curve v1

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

Development caught three real bugs, all fixed and regression-tested: a migration
threshold that exceeded the curve's token capacity (big buys near graduation would
revert forever), a 1-wei rounding gap that could reject legitimate sells, and a
migration-bricking grief where a pre-seeded Uniswap pair's ETH refund would revert
against the factory. The constructor now enforces threshold < depletion capacity.

If you change any curve parameter, rerun `forge test --fuzz-runs 2000` — the
parameters are load-bearing on each other, not independent knobs.

## Curve economics (pump.fun-shaped, verified July 2026 prices)
Curve parameters are constructor args set at deploy time (env vars in Deploy.s.sol):

**Mainnet reference** — `VIRTUAL_ETH=1.1 ether`, `VIRTUAL_TOKENS=1,073,000,000e18`,
`THRESHOLD=3 ether`:
- Graduates at 3 ETH raised (~$5.4K at ETH $1,800) — just under pump.fun's ~$6.5K bar
- Graduation mcap ~14.2 ETH (~$25.6K): a 4.7x mcap/raise ratio (pump.fun structural: ~4.8x)
- 13.9x price multiple start→graduation (pump.fun: ~14.7x)
- Curve depletes at 3.22 ETH → 7.4% safety headroom above threshold (constructor-enforced)
- Pool receives 3 ETH + ~215M tokens at a price within 2% of the final curve price

**Testnet demo** — same shape ÷1000: `VIRTUAL_ETH=1100000000000000`
`THRESHOLD=3000000000000000` (wei). Graduation at 0.003 ETH fits a faucet budget.

Note: thresholds are ETH-denominated, so a big ETH price move shifts the dollar bar
(same exposure pump.fun has with SOL). Revisit if ETH doubles.

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
2. **Frontend** — done: `stampede.html` (wallet connect, launch, trade, graduation progress).
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
