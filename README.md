# Surewould

A bonding curve launchpad for [Robinhood Chain](https://chain.robinhood.com) (Arbitrum-based L2, chain ID 4663).

Anyone can launch a token with no presale and no seeded liquidity. Trading starts in the
same transaction the token is created. Once the curve raises its graduation threshold,
liquidity migrates to Uniswap V2 automatically and **the LP tokens are burned** — the
initial pool can never be pulled, by anyone, including the launchpad operator.

Live on testnet: **[surewould.fun](https://surewould.fun)**

## Contracts

| File                       | Purpose                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------- |
| `src/LaunchToken.sol`      | Plain ERC20. Fixed 1B supply, no mint function, no admin functions.                     |
| `src/BondingCurve.sol`     | Pricing engine — constant-product buy/sell against virtual reserves, migration trigger. |
| `src/LaunchpadFactory.sol` | Deploys token+curve pairs, executes the Uniswap migration and LP burn.                  |
| `script/Deploy.s.sol`      | One-command deploy for testnet or mainnet.                                              |
| `test/`                    | 28 Foundry tests including fuzzing.                                                     |

## How it works

**Pricing.** `x * y = k` against _virtual_ reserves, so the curve has a sane starting
price without anyone seeding liquidity. _Real_ reserves track what's actually been
collected — that's what determines graduation and what gets paired into the pool.

**Token split.** 1B fixed supply: 800M sellable on the curve, 200M reserved to pair with
the raised ETH at migration. 1B circulating = 1B max supply, no inflation.

**Oversized buys are capped, not rejected.** If a buy asks for more tokens than the curve
still holds, it fills at the remaining inventory and refunds the unused ETH in the same
transaction. Buys never revert for exceeding the curve. The buy that empties it graduates it.

**Creator first-buy is atomic.** `launch()` is payable — ETH sent with a launch executes
the creator's buy inside the token's creation transaction. There is no block in which a
sniper can act first.

**Fees.** 1% per trade to `feeRecipient`, set at deploy time.

## Curve parameters

Set as constructor args at deploy time, so one audited contract serves any scale.

**Mainnet reference** — `VIRTUAL_ETH=1.1 ether`, `VIRTUAL_TOKENS=1_073_000_000e18`, `THRESHOLD=3 ether`:

|                                     | Value                                                           |
| ----------------------------------- | --------------------------------------------------------------- |
| Graduates at                        | 3 ETH raised                                                    |
| Graduation market cap               | ~14.2 ETH (~4.7x the raise)                                     |
| Price multiple, launch → graduation | ~13.9x                                                          |
| Curve depletion point               | 3.22 ETH (7.4% headroom, constructor-enforced)                  |
| Pool receives                       | 3 ETH + ~215M tokens, priced within 2% of the final curve price |

For reference, pump.fun's structural ratio is ~4.8x mcap/raise with a ~14.7x price
multiple — this curve is deliberately shaped the same, scaled for a younger chain.

**Testnet** uses the identical shape ÷1000 (`THRESHOLD=0.003 ether`) so a faucet-funded
wallet can take a token through the full lifecycle.

Thresholds are ETH-denominated, so a large ETH price move shifts the dollar bar. Same
exposure pump.fun has with SOL.

## Tests

```bash
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge test
```

28 tests, all passing, including a fuzz test that crosses the depletion boundary.

Testing caught four real bugs, all fixed and regression-tested:

- A migration threshold above the curve's token capacity — buys near graduation reverted forever
- A 1-wei rounding gap that could reject legitimate sells
- A migration-bricking grief: a pre-seeded Uniswap pair's ETH refund reverted against the factory
- Oversized buys reverting instead of capping and refunding

The curve parameters are load-bearing on each other, not independent knobs. If you change
one, rerun `forge test --fuzz-runs 2000`.

## Deploying

```bash
export PRIVATE_KEY=0x<deployer_key>
export FEE_RECIPIENT=0x<wallet_that_receives_the_1%>

# testnet (no Uniswap deployed there — the script deploys a mock router as the target)
export USE_MOCK_ROUTER=true
export VIRTUAL_ETH=1100000000000000
export THRESHOLD=3000000000000000
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast

# mainnet (omit VIRTUAL_ETH/THRESHOLD to use the reference values above)
export USE_MOCK_ROUTER=false
export ROUTER=0x89e5db8b5aa49aa85ac63f691524311aeb649eba
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast
```

Then set `DEPLOYED_FACTORY` in `index.html` to the printed factory address.

### Addresses

- **Mainnet (4663) Uniswap V2 Router02:** `0x89e5db8b5aa49aa85ac63f691524311aeb649eba`
- **Mainnet V2 Factory:** `0x8bceaa40b9acdfaedf85adf4ff01f5ad6517937f`
- **Testnet (46630):** no Uniswap deployment — mock router used

Re-verify against [Uniswap's deployments page](https://developers.uniswap.org/docs/protocols/v2/deployments)
before any mainnet deploy.

## Status and limitations

Testnet only. Read this part before trusting it with anything:

- **Unaudited.** Well-tested is not audited. No independent review has been done.
- **Testnet graduation migrates to a mock router, not real Uniswap** — there's no live
  pool behind a testnet graduation. The migration mechanism is real; the destination is a stub.
  Only mainnet, with the router above, creates a tradeable pool.
- **`completeMigration` passes `0, 0` for slippage bounds.** Fine for testing. Needs real
  bounds before mainnet.
- **Frontend buys/sells pass `minOut = 0`** — no slippage protection. Same caveat.

Found something broken? Open an issue.

## License

MIT
