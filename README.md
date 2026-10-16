# TICKS contracts

The TICKS token and its launch on Robinhood Chain.

## What's in here

- `src/TicksToken.sol`: the token. A standard OpenZeppelin ERC-20 with a fixed supply minted once at deployment. No owner, no minting afterwards, no transfer tax, no blacklist, no pause.
- `script/Launch.s.sol`: deploys the token and opens its Uniswap v4 pool in one run.
- `script/LaunchPlan.sol`: the pool setup. A standard v4 pool with no hook and a static pool fee (3% by default). The pool starts with TICKS only, so the launch needs no capital on the other side: buys move the price up into the position, and the pool fee on every trade goes to the wallet that owns the position.
- `script/CollectFees.s.sol`: collects the fees the position has earned (the Uniswap app can do the same under Positions).
- `tools/send-tokens.mjs`: sends TICKS to a list of wallets from a CSV. Used for the supply distribution and for each season's rewards, straight from the admin's PAYOUTS export. Every confirmed transfer goes into a ledger, so a stopped run can be restarted without paying anyone twice.
- `test/Launch.t.sol`: runs the whole launch against the real Uniswap v4 deployment on a fork of Robinhood Chain mainnet, with ETH and USDG pairs.

Only audited, widely used code is involved: OpenZeppelin Contracts v5.7.0 for the token and the official Uniswap v4 contracts already deployed on Robinhood Chain for the pool.

## Setup

```sh
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge install
npm install
cp .env.example .env
```

## Test

```sh
forge test -vv
```

## Launch

```sh
# 1. Deploy the token and open the pool (fill the launch section of .env first)
forge script script/Launch.s.sol --rpc-url robinhood --broadcast --private-key $DEPLOYER_KEY

# 2. Distribute the rest of the supply (check first, then add --send)
node tools/send-tokens.mjs --file allocation.csv --token <TOKEN>

# 3. Each season, pay the rewards from the admin's PAYOUTS export
node tools/send-tokens.mjs --file season-1-payouts.csv --token <TOKEN> \
  --address-column wallet_address --amount-column total_ticks
```

## Addresses on Robinhood Chain

| Contract | Address |
| --- | --- |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap v4 PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
