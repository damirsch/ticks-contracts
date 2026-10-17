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

## Testnet

Robinhood Chain testnet has the same Uniswap v4 contracts as mainnet, but not the Universal Router the Uniswap app uses, so the testnet has its own small page instead.

1. Get test ETH from the official faucet (https://faucet.testnet.chain.robinhood.com) for the deployer and for the MetaMask account you will test with.
2. Deploy everything, with your test account as the pool owner:

```sh
OWNER=<your test account> forge script script/TestnetSetup.s.sol --rpc-url robinhood_testnet \
  --broadcast --private-key $TESTNET_DEPLOYER_KEY
node tools/find-position.mjs TestnetSetup 46630 deployments/testnet.json
```

The second command records the position NFT the broadcast actually minted: a script only knows the id it simulated, and on a busy chain someone else's mint can take that id first.

3. Start the page and open http://127.0.0.1:8091/tools/testnet-ui/ to buy, sell and collect the pool fee with MetaMask:

```sh
npm run ui
```

To share it, `npm run site` publishes only the page and `deployments/testnet.json` to Vercel (the project is called ticks-testnet).

The pool holds only TICKS at launch, so the launch price is a floor: a sell can only take the ETH that buyers have put in. The page caps a sell at that price, so selling more than the pool can pay leaves the rest in your wallet instead of pushing the price into the empty range below it.

## Launch

```sh
# 1. Deploy the token and open the pool (fill the launch section of .env first). The key lives in
#    Foundry's encrypted keystore so it never lands in the shell history: cast wallet import deployer --interactive
forge script script/Launch.s.sol --rpc-url robinhood --broadcast --account deployer
node tools/find-position.mjs

# 2. Right away, before the address goes public, the owner locks the position. Titan Locker
#    (createPositionLock on 0x102a70bDA2C833b3483A2eE55C14c7ea0fb7A01B) takes 0.025 ETH and nothing else.
#    UNCX (app.uncx.network, Manage, V4 Liquidity) takes 0.1 ETH and 1% of the position and keeps 4% of
#    the fees collected later. test/Lock.t.sol runs both real lockers on a fork to show every rule

# 3. Distribute the rest of the supply (check first, then add --send)
node tools/send-tokens.mjs --file allocation.csv --token <TOKEN>

# 4. Each season, pay the rewards from the admin's PAYOUTS export, from a payout wallet that holds only
#    this season's TICKS (the rest of the rewards stay in the cold wallet)
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
