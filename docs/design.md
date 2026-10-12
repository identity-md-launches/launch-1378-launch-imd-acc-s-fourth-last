# imd/acc design notes

The [README](../README.md) is the overview. This file keeps the design detail and the reasons behind each decision: the parts of the system, how points and the dashboard work, the multichain route, the planned ETH route and project registry, the launch settings and the open questions.

## Building blocks

| Part | What it does |
|---|---|
| `Stacker` (shared contract) | `credit(trader, imdAmount)`: pulls IMD from the caller and calls `sIMD.deposit(amount, trader)`. The caller is the project. Emits `Stacked(project, trader, imd, shares)` and keeps per-project totals on chain. No owner; the IMD and sIMD addresses are immutable. Deposits on every credit. |
| Integration rule | The project wraps `credit` in `try/catch`. If it fails (vault paused, anything else), the hook sends the cashback to the trader as plain IMD instead, so **a trade never reverts because of imd/acc**. |
| Drop-in hook (planned) | For IMD pools without their own hook. Takes the cashback in IMD in `afterSwap` and calls `credit`. Includes the `afterSwap` logic that Uniswap's frontend whitelisting needs (a btc/acc lesson). |
| Trader identity | The router passes the real trader in `hookData`. Fall back to `sender`; never use `tx.origin`. |
| Site | "Your stack" (sIMD from cashback, per project, and its IMD value now), plus leaderboards for top stackers and top projects. |

## Which projects earn points

Anyone can call `credit` with their own IMD. That is just staking for someone, and it can't be blocked without giving the Stacker an owner. So points are counted, not gated: the Stacker records everything, and only credits from **listed projects** earn points. Every `Stacked` event names its project, so the list can be applied at any time.

**Today (decided): a list file.** Credits from anything not on the list show as "direct, no points". Real trading points already cost money (fees paid to trade), so the only cheap attack was a fake project, and the list closes it. The first test page shipped its own `projects.json`; from Sepolia test run 2 the list is a file in this repository, `listings/<chain>.json`, so a listing is a commit, not a paid job. How a project applies, the checklist, the fee guard and delisting with `toBlock` are in [listing.md](listing.md).

**Points start at listing.** A listed project's credits earn points only from its `fromBlock`, never retroactively, so nobody can build fake history and then get approved. A project reviewed before or at launch gets its deploy block (PLEA's case).

**Next: the IMD panel decides the list** through the ProjectRegistry, below, from Sepolia test run 2 on. The Stacker never changes.

## The ProjectRegistry

**Built and tested (2026-10-11); it ships in Sepolia test run 2, and PLEA's next version is the first applicant.** Code: [`src/ProjectRegistry.sol`](../src/ProjectRegistry.sol). A small contract with **no owner** decides the list through IdentityMD oracle panels, so nobody decides alone. **Nothing is redeployed:** the Stacker doesn't know about listings, so the site and the indexer read the registry's events instead of a list file.

**Oracle: Intake v2**, `0xa43e6f75ee006411f79ac1c84120606c2330de82`, the same address on Ethereum, Sepolia and Robinhood Chain. The registry asks with `requestWithFailure`, so a refused question or a split panel calls it back too. Callback gas: 200,000 on mainnet, 1,000,000 on Sepolia. Checked against the live contract: the four functions the registry calls are in its code, and on a Sepolia fork the real Intake took the fee and recorded both callbacks.

### How it works

| Step | Who | What happens |
|---|---|---|
| `applyListing(project, name, sourceUrl, rateBps, beneficiary)` | anyone | Pays the oracle fee (`ORACLE_FEE()`, read live from the Intake: 0.5 IMD today) and sends a yes-or-no question about the project. The project must be a contract, the rate 25-100 bps; name and URL are short printable ASCII (no quotes, backslashes or brackets) and go into the question as untrusted text. One open question per project at a time. |
| Signed **yes** | oracle panel | Listed from this block (`Listed`), with the stated rate and beneficiary. No challenge for `challengeCooldown`. |
| Signed **no** | oracle panel | `Rejected`. The project can apply again. |
| `challengeForBeneficiary(project, reason, beneficiary)` | anyone | Only for a listed project, after its cooldown, naming the beneficiary the challenger saw (it reverts if that changed). Pays the oracle fee plus `challengeBond`. The panel is asked whether the project still meets every rule. `challenge(project, reason)` also works until the project's first beneficiary handoff. |
| Challenge, signed **yes** (still meets the rules) | oracle panel | Stays listed (`Defended`); **the bond goes to the project's beneficiary**. No new cooldown starts, so a project can't buy quiet time by challenging itself (an IMD audit finding). |
| Challenge, signed **no** | oracle panel | Delisted from this block (`Delisted`); **the bond goes back to the challenger**. Points before this block stay. The project can apply again later; a new listing starts a new period. |
| No answer (refused or split panel) | Intake, through `onOracleFailure` | The open question is cleared (`AskCleared`) and a challenger's bond goes back. Nothing is listed or delisted. |
| `expire(project)` | anyone | Clears an open question after a day, or at once if the Intake completed it without a settled answer (for example a callback that ran out of gas). A challenger's bond goes back. |
| `setBeneficiary(project, wallet)` | the current beneficiary | Hands a listed project's points to another wallet. Refused while a question is open, and at most one handoff per day (`HANDOFF_INTERVAL`), so a beneficiary can't refuse every challenge by moving the wallet ahead of each one; after any handoff, challenges must use `challengeForBeneficiary`. |
| `claimBond(to)` | whoever is owed a bond | Takes the bonds the oracle asset refused to pay them at settlement (`bondOwed`), sent to `to`, which may be another wallet. Settling, failing or expiring a question never waits on paying a bond: if the token refuses the transfer (a wallet it blocks, a `false` return), the bond is recorded as owed (`BondOwed`) and the question still closes, so a refusing token can't hold a project's question open for good (a Sepolia test run 3 audit finding). |

### What the panel is asked

The question names the Stacker, the project, the chain and the registry, the stated rate and beneficiary, and the applicant's name and URL as untrusted text. It asks for **true only if every rule holds**, judged from the verified source and on-chain state:
- **trading:** a trading venue that calls `credit` only while executing a trade, for that trade's trader, with IMD from that trade's fees;
- **rate:** at application, the stated rate is the one in force and lies between 25 and 100 bps; at a challenge, the rate in force lies between 25 and 100 bps (the application rate is historical, as deployed on Sepolia); if the rate can change, the code keeps it in that range;
- **feeGuard:** the parts of the fee that leave for good are at least the cashback. For mainnet, the wording adds: if the rate or the fee split can change, the code must keep this true for every allowed setting;
- **beneficiary:** the project's owner, or a wallet its verified source or official website names as its team or treasury. This stops someone from applying for another team's project with their own wallet as beneficiary;
- **evidence:** the verified source on the chain's explorer; unverified code means false.

**Version 2 (2026-10-12, in `src/ProjectRegistry.sol` on `main`; the deployed Sepolia registry still sends version 1):** after PLEA's applications split the panel, clearer rules were written and rehearsed (11 of 13 yes, signed): [panel-rules-v2.md](panel-rules-v2.md). They add that a plain-IMD fallback or other uncredited payout is allowed and earns no points, that the trader may come from the swap caller's `hookData`, that value no owner or team wallet can ever withdraw leaves for good, and that Etherscan, Blockscout or Sourcify count as verified source. Each rule must stay under 512 characters.

A challenge asks whether the listed project still meets all of them, with the challenger's reason as untrusted text. Panel: 15 seats, 11 must agree. IMD's free check accepted this question (no blockers, judged answerable).

**Filed under chain 1.** The oracle has no Sepolia RPC (its check refuses chain 11155111), so Sepolia questions are filed under chain 1, like PLEA's gate does, and the text names Sepolia. The registry's `questionChainId` is 1 on Sepolia and mainnet; it would be 4663 on Robinhood Chain.

### What an answer must pass
1. It comes from the Intake, for a request this registry made and hasn't settled.
2. It is signed by the oracle signer `0x5598…2982` in this contract's EIP-712 domain ("IdentityMD Oracle", version 2), and is not expired.
3. It was issued after the question was asked, so an older answer can't be reused.
4. It is filed under `questionChainId`, from a panel of at least 15 with at least 11 agreeing (and at least its own signed quorum), and it is a bool.
5. Its oracle request id hasn't been used before; each answer is consumed once.

It does not pin the question's hash. Like PLEA's gate, it relies on the Intake pairing each answer with the right request, which is what IMD's docs recommend for a contract that asks on its own chain. Pinning the hash would mean rebuilding IMD's canonical JSON on chain, with a high cost if it is wrong by one byte.

### Money it holds
Only the bonds of open challenges and the bonds owed to wallets the token refused to pay (`bondOwed`, until claimed), never anything else, and never an approval left to the Intake (each ask approves exactly the fee, which the Intake takes at once). A failure or an expiry returns a bond to the challenger who paid it. That is the only value an unsigned failure moves, and it gives the Intake's writer no power it doesn't already have: withholding an answer leads to the same refund through `expire`.

### Settings

Confirmed by the owner on 2026-10-11, for both chains.

| Setting | Sepolia test run 2 | Mainnet |
|---|---|---|
| Oracle fee | 0.5 test IMD (anyone can mint it) | 0.5 IMD |
| Challenge bond | 5 test IMD (`5e18`) | 20 IMD (`20e18`, about $170 at $8.58 per IMD) |
| Challenge cooldown | 1 hour (`3600`) | 7 days (`604800`) |
| Panel | 15 seats, 11 agree | same |
| Open question expires | after 1 day | same |

**Why these numbers.** On Sepolia the bond only tests the flow (test IMD is free), and a 1-hour cooldown lets the trial run its challenge step on the same day. On mainnet, 20 IMD (40 times the oracle fee) makes challenging a project just to annoy it costly, since a defended challenge pays the bond to the project, while staying within reach of someone who has really caught a project breaking the rules. Seven days gives a listed or defended project a quiet week; a project that starts cheating can still be challenged within a week, and its points stop from the block it is delisted.

### Known limits
- **Blocking by spam:** someone can keep a project's application slot busy by applying for it with wrong terms, one question at a time. Each try costs them 0.5 IMD and lasts until the panel answers (minutes).
- **Fixed oracle settings:** the signer and the action id (`oracle.request@oracle-1`) are fixed in the contract; the fee is read live from the Intake, and a zero price (the action retired) makes asking revert. The cooldown is capped at 365 days. If IMD changes them, a new registry is deployed, and the site reads both, so listing history is kept.
- **Writer trust:** the Intake's writer can withhold an answer or pair one with the wrong request. That suits a listing decision, which can wait and be challenged.

### Tests
`test/ProjectRegistry.t.sol` (23 tests) covers every path and check above, including the answers fitting mainnet's 200k callback gas. `test/ProjectRegistryInvariant.t.sol` runs random sequences and checks three things: the registry holds exactly the open bonds and no approval; every record matches its open question and listing; listings minus delistings equals the projects listed now. `test/RegistrySepoliaFork.t.sol` runs against the real Intake v2 on a Sepolia fork: an application costs about 423k gas, and a listing answer 77k.

### Sepolia trial with PLEA
1. Test run 2 deploys the Stacker and the registry.
2. PLEA's next version credits through that Stacker and applies at 50 bps with its beneficiary. Expected: yes.
3. Negative cases: a plain wallet (refused before asking, since it has no code), and a contract that credits its own IMD ([`SelfCredit`](../test/trial/SelfCredit.sol), deployed at `0x3d17…1488`). Expected: no.
4. A no-answer case, to see the failure callback clear the application.
5. A challenge against PLEA. Expected: it stays listed and the bond goes to its beneficiary.
6. The test page shows the registry's state and counts points by its listing periods.

**Results so far (2026-10-12, [history section 17](history.md#17-registry-trial-pleas-first-applications-2026-10-12)):** PLEA applied twice and both panels split (8 and 9 of 13 yes, 11 needed), so both were cleared as no-answer cases; the false answers read the plain-IMD fallback, a claims payout that skips the Stacker and the trader from `hookData` as breaking the trading rule. The negative case `SelfCredit` was rejected 12 to 0 with a signed answer. The listing and challenge steps wait for a listed project.

## Points now, token maybe later

v1 has **no token**:
- The product is IMD, and a second token would compete with it.
- imd/acc takes no cut, so a token would have nothing behind it.
- Projects adopt a neutral tool more easily.

What v1 does keep is a full **points record** from day one. Every `Stacked(project, trader, imd, shares)` event counts:
- **Trader points**: the IMD stacked for them, all-time, across all listed projects.
- **Project points**: the IMD its traders stacked.

This history drives the leaderboards. If imd/acc takes off, it's the basis for a later token, launched through the IMD swarm and **airdropped to early stackers and integrating projects**. Nothing is promised: points are a record, not a claim. A token would only make sense if imd/acc adds something for it to back, such as a small protocol cut, an integration-incentive budget, or a vote on featured projects.

## Cashback rate: 0.25% to 1%, chosen by each project

**Decided 2026-10-11** (it was a fixed 0.5%). Each project picks its rate between 0.25% and 1% of each trade. Lower lets projects with thin fees join; higher lets projects attract traders. PLEA uses 0.5%.

- **No contract change.** The Stacker never checked the rate: it stakes whatever amount the project sends. The rate is a listing rule.
- **Points stay "1 per IMD stacked".** A project with a higher rate gives its traders more cashback and so more points. Points stay tied to real IMD that reached traders, which is easy to verify for any kind of project.
- **The guard against farming.** A project owner who trades with themselves gets back the cashback and their own share of the fee. So the part of the fee that really leaves the project (to liquidity providers, burns, prizes) must be at least as large as the cashback. Then farming points always costs more than it brings back. PLEA: 0.5% cashback, 0.75% to liquidity, burn and prizes.
- **Listing.** Each listing records the rate the project applied with (`rateBps`, 25 to 100). The listing check (the list file, or the ProjectRegistry panel) reads the project's verified code to confirm the rate and the guard.
- **Rate changes (decided 2026-10-11).** A listed project may change its rate within 25 to 100 bps and stays listed, provided its code enforces that range and keeps the fee guard true for every rate and fee split it allows. The panel checks this at application and at any challenge. Why: points are 1 per IMD that really reached traders, so a rate change inside the range fakes nothing, and delisting a project for an honest change would cost it its listing period and a new application. The condition closes the one gap: without it, a project could raise its rate past its guard right after listing, during the cooldown when nobody can challenge it.
- **Indexer.** It compares each credit with the swap in the same transaction. A credit outside 25 to 100 bps of that trade, or with no trade on the project's pool, earns no points.
- **Dashboard.** Each project shows its current rate, measured from its recent credits against their trades, with the application rate marked as historical, so a project that listed at 1% and later dropped to 0.25% can't mislead traders.
- **Gas.** At 0.25%, a credit's gas (about 2¢ for a new trader today) is outweighed by the cashback on trades above about $10, against $5 at 0.5%.

## Project points and the dashboard

**Decided 2026-10-11.** Points and every dashboard figure come from the `Stacked` events. The mainnet Stacker stores only per-project totals on chain.

**Why not store per-trader totals on chain:** they repeat what the events already record, and they can't be the points anyway, because they count everything (unlisted projects, direct self-stacks, credits before a project was listed). Dropping them makes every credit cheaper (mainnet fork, whole transactions):

| Stacker | New trader | Repeat trader |
|---|---|---|
| Sepolia version (per-trader totals on chain) | 197k gas | 112k gas |
| Mainnet version (this repository) | 136k gas | 102k gas |

The only thing lost is that another contract can't ask the Stacker directly for one trader's total. A later airdrop would use a snapshot of points with claim proofs anyway.

**Project points** are the IMD cashback a project paid its traders. It's real IMD that left the project, so it can't be faked cheaply. Rules for the indexer:
- Count a project's credit only when the same transaction also has a swap on that project's pool, so a project can't credit its own wallets for points. Trading back and forth already costs more in fees than it earns.
- Show next to it: the project's rate, unique traders, number of trades, estimated volume (cashback ÷ the project's rate), all-time, 7-day and 30-day.
- Each listing carries a `beneficiary` wallet (in `projects.json` now, in the registry later), because the project address is a hook contract that can't receive an airdrop.

**What a trader sees**, all from our site:
- cashback received, points and the split per project: their events;
- sIMD held now: the vault's `balanceOf`, live;
- what their cashback is worth today: the shares recorded in their events, priced by the vault's `convertToAssets`, live. This values only the cashback shares, even if they hold other sIMD;
- earned on top: worth today − cashback received.

**Where the list lives (2026-10-11, test run 2):** the new test page fetches `listings/sepolia.json` from this repository on GitHub (CORS is open), with a bundled copy as fallback. Each entry is `{address, name, fromBlock, rateBps, beneficiary}`. Listing a project is a commit, instead of a paid site job each time. The trust is the same as before (whoever controls the list); the ProjectRegistry replaces it later.

**Indexer:** the test page scans events in the browser, which is fine for hundreds of events and too slow for thousands. IMD's `build-ponder-indexer` skill builds an indexer that keeps every chain's events in a table and serves the site. Order: mainnet Stacker, then the indexer, then the mainnet dashboard.

## Multichain: cashback from other chains

**Decided 2026-10-11 (design; not built yet).** The sIMD vault exists only on Ethereum. On other chains, cashback waits per trader on that chain and is delivered to Ethereum as sIMD through **IMD's own LayerZero bridge**. Robinhood Chain comes first (PondPad), then Base and Arbitrum.

**Facts checked on chain (2026-10-11):**
- IMD on Ethereum is a LayerZero OFT (v2) linked to Arbitrum (eid 30110), Base (eid 30184) and Robinhood Chain (eid 30416, IMD `0x5f7b…7127`). No new bridge is needed; anyone holding IMD on those chains already trusts it.
- It supports send-and-call ("compose") and has no message inspector blocking it.
- It moves amounts in steps of 0.000001 IMD (6 shared decimals); smaller dust stays on the source chain.
- Its enforced options cover only plain sends (60k gas on arrival), so a send-and-call must carry its own gas options.
- Ethereum's LayerZero endpoint is `0x1a44076050125825900e736c501f859c50fE728c` (eid 30101).
- IMD can launch on Sepolia, Ethereum and Robinhood Chain today, not yet on Base or Arbitrum.

**Two new contracts, both with no owner:**

| Contract | Where | What it does |
|---|---|---|
| `RemoteStacker` | each other chain | Same `credit(trader, imdAmount)` as on Ethereum, so integrating is identical. Pulls the IMD, adds it to the trader's waiting balance, and emits `Queued(project, trader, imd)` at once: that is the points record. Its `flush(traders)` sends waiting cashback to Ethereum. |
| `StackReceiver` | Ethereum | Receives the IMD plus the list "trader → amount" and calls `sIMD.deposit(amount, trader)` for each. |

**How the waiting cashback is stored:** in the RemoteStacker. The IMD sits in its own balance; for each trader it records the amount waiting and the waiting clock. All of it is public.

**Who can do what:**

| Who | Can | Can't |
|---|---|---|
| A project | add IMD for a trader, from its own IMD | take anything out |
| Anyone | call `flush` with up to 50 traders and earn their tips | choose where it goes or change an amount |
| A trader | flush their own cashback right away, paying the bridge fee | anything else |
| Us, or any owner | nothing: no owner, admin, pause or upgrade | withdraw, redirect or freeze |

The only way out is to the StackReceiver, whose address is fixed at deploy. The tip is computed by the contract, never chosen by the caller. IMD's bridge is configured by the IMD team; that's the one outside trust.

**No fixed batches.** An earlier draft sent batches in order, so 50 junk entries with almost no value could block every batch behind them. Instead, each trader has their own waiting balance and whoever flushes picks up to 50 of them. Junk just sits and blocks nobody.

**The tip (decided 2026-10-11):** each trader's tip is 2% × (hours waiting ÷ 12) of their waiting cashback, at most 2%. It goes, in IMD, to whoever flushes, who pays the bridge fee (in the chain's gas token).
- The clock is the amount-weighted average arrival time, so new cashback doesn't inherit an old clock.
- The same rule applies to every amount. The trader always gets at least 98%, and usually more: someone flushes as soon as the tips cover their cost (about $1 for 50 traders at today's Ethereum gas, an estimate), and a big waiting balance or many traders together get there sooner.
- On a quiet chain, small amounts may wait longer than 12 hours, but the cut stays at 2%.
- imd/acc takes nothing. On Ethereum there is no tip: the cashback is staked inside the trader's own swap.

**Rules both contracts must follow:**
1. **Balance always matches:** the RemoteStacker's IMD equals the sum of all waiting balances, apart from tips already paid out.
2. **Atomic flush:** if anything fails (bridge fee too low, a revert), every waiting balance stays exactly as it was.
3. **No double pay:** a trader listed twice in one flush is delivered once (the second entry finds nothing waiting).
4. **Dust stays with the trader:** each delivered amount is rounded down to the bridge step; the rest stays in that trader's waiting balance.
5. **The contract sets the Ethereum gas** for the delivery (a base plus a fixed amount per trader), not the caller, so nobody can buy too little gas on purpose. If delivery still fails, anyone can retry it through LayerZero with more gas.
6. **The receiver** accepts only calls from LayerZero's endpoint for IMD's own token. It hands out only the IMD that arrived in that message, and only if the listed amounts add up to it; a sender that lies about its own IMD can only lose its own IMD. If a deposit fails, that trader gets plain IMD on Ethereum. It keeps no IMD after a delivery.
7. **Smart-contract wallets** (a Safe, some smart wallets) may not exist at the same address on Ethereum. They're paid plain IMD on their own chain at once, unless they register an Ethereum address for themselves. Plain wallets, including EIP-7702 ones, go through the queue.
8. **Points** are counted on the chain where the trade happened, when it happened. A slow or retried delivery never changes points.
9. **Launchable:** no constructor may revert on IMD's empty-chain rehearsal.

**How we make sure it's right:** spec (this section) → contracts with unit, fuzz and invariant tests (rules 1–4 as invariants), LayerZero's test helpers for the bridge, and forks of Ethereum and Robinhood Chain with the real IMD and sIMD → IMD launches (StackReceiver on Ethereum, RemoteStacker on Robinhood Chain) with the four-specialist audit, judge and independent review → a small live test with a few IMD → PondPad integrates.

**Accepted trade-offs:** the trader's sIMD lands on Ethereum, not on their own chain; delivery waits for the next flush; and it relies on LayerZero and IMD's bridge setup. A later step could send bridged sIMD back to the trader's own chain, or use local vaults if the IMD team deploys sIMD on other chains (worth asking them).

## Who pays the gas

- **On Ethereum:** the trader, inside their own swap. The project pays no extra gas, and imd/acc has no treasury or relayer. With the mainnet Stacker that is about 0.11M gas for a new trader and 0.075M for a repeat one, beyond the base cost of the swap: under 2¢ at today's 0.06 gwei and ETH at $2,505.
- **On other chains:** the trader's own swap pays the small local `credit`; delivery to Ethereum is paid by the tip above.
- **The v2 ETH route** would use the same rising tip for its `flush()`.

## v2: projects whose fees are in ETH

**Not built yet.** The first projects (PLEA, PondPad) collect their fees in IMD, so they can deposit straight into the vault. Projects paired with ETH, or with fees in ETH, use a batched route instead:

1. **On each trade**, the hook takes its cashback in ETH and calls `creditETH(trader)`. The ETH is recorded as the trader's `pendingETH`. Nothing is swapped yet, so it costs little gas.
2. **`flush()`** can be called by anyone, for a small tip like POOL4's keepers get. It:
   - swaps the pooled ETH to IMD in one trade through **POOL4**, IMD's main IMD/ETH pool
   - deposits that IMD into sIMD
   - gives each trader shares in proportion to their `pendingETH`
3. The trader's sIMD goes up after each flush.

Safety rules:
- **Price guard:** the swap must return at least a minimum amount of IMD, measured against a recent average price (TWAP) rather than the price at that moment.
- **Maximum batch size** per flush, so one flush can't move POOL4's price much.
- **Pending ETH can't go anywhere else.** It can only be swapped and credited to the trader it was recorded for.
- The order is fixed: the swap happens first, then shares are split, with rounding in the vault's favour.

Why not swap on every trade: a second swap inside each trade roughly doubles gas on Ethereum, and small swaps made mid-trade are easy to sandwich. One guarded batch avoids both.

Side benefit: POOL4 burns a cut of IMD on its trades, so every flush also burns some IMD.

## Decided

- **Owner:** the Stacker has none, and its IMD and sIMD addresses are immutable. TestSIMD keeps an owner on Sepolia only, so integrators can pause it and test their fallback; mainnet uses the real, renounced sIMD.
- **Gas:** v1 deposits on every credit. Batching comes in v2 with the ETH route.
- **Build:** an IMD `evm_contracts` launch, shipped before PLEA so PLEA could reuse its addresses.
- **Points:** listed projects only, from their `fromBlock` (see above). 1 point per IMD stacked.
- **Cashback rate:** 0.25% to 1% of each trade, chosen by each project and funded from its existing fees (was a fixed 0.5% until 2026-10-11; see above). A listed project may change its rate within that range if its code keeps the range and the fee guard for every allowed setting (decided 2026-10-11).
- **Mainnet Stacker (2026-10-11, constructor changed 2026-10-12):** the lean version in this repository: per-project totals on chain, per-trader figures from events. Since 2026-10-12 it is the exact contract IMD's audit deployed on Sepolia: the constructor makes no external call and the first credit checks and approves the vault (about 2.2k gas more per credit). It used to check the vault in the constructor where the vault has code, so IMD's empty-chain rehearsal passes.
- **Dashboard (2026-10-11):** points, leaderboards and each trader's cashback, value and yield come from the events plus live vault reads, served by an indexer.
- **ProjectRegistry (2026-10-11):** anyone may apply or challenge; one registry per chain; a defended challenge pays the bond to the project's beneficiary, a lost one returns it; no application fee beyond the oracle fee. First on Sepolia test run 2 with PLEA.
- **Registry settings (2026-10-11):** panel 15 seats with 11 agreeing, open questions expire after 1 day; Sepolia bond 5 test IMD and cooldown 1 hour; mainnet bond 20 IMD and cooldown 7 days ([settings](#settings)).
- **Multichain (2026-10-11):** per-trader waiting balances on other chains, delivered to Ethereum through IMD's bridge, paid by a tip of up to 2% that rises over 12 hours.

## Open questions

1. **Is an sIMD vault planned on Robinhood Chain?** IMD exists there (`0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, the same OFT), but no vault does. **Recommendation:** ask the IMD team whether they will deploy StakedIMD there; until then PondPad pays its cashback as plain IMD. A Stacker on Robinhood Chain is a one-contract launch once a vault exists.
2. **Should sells get cashback too, or buys only?** (PLEA pays it on every trade.) **Recommendation:** both. Every trade pays a fee, so every trade funds its 0.5%; wash trading for points still loses money, because the fees on a round trip are larger than the cashback.

Known and harmless: a credit mints sIMD to the trader, and the vault's one-block hold then stops that trader from redeeming in the same block. Anyone can already do this by depositing into the vault for someone, so the Stacker adds nothing new.

## Launch settings

### Sepolia (launch #1129, live)

| Field | Value |
|---|---|
| Action | `launch.open` |
| Launch type | Smart contracts (`evm_contracts`) |
| `chainId` | `11155111` (Sepolia) |
| `owner` | `0x4b91078b2374c956a65f7af0999cae0a935e6821` (TestSIMD's owner, who can pause it to test the fallback) |
| Contracts, in order | `TestIMD`, `TestSIMD`, `Stacker` |
| `ipfs` | `"imd-acc-test"` (IMD named the site `imd-acc-sepolia-test-run`) |
| `github` | `true` |
| `references` | `evm-contracts-launch`, `defi-native`, `eth-security`, `eth-testing`, `eth-frontend-ux`, `better-interface`, `pashov-skill`, `solidity-security-review` |
| Prompt | [`jobs/1-sepolia-launch.md`](../jobs/1-sepolia-launch.md) |

### Ethereum mainnet (ready, not paid)

| Field | Value |
|---|---|
| Action | `launch.open` |
| Launch type | Smart contracts (`evm_contracts`) |
| `chainId` | `1` (Ethereum mainnet) |
| Source | `repoUrl` this repository, `khaed1/imd-acc`, at the commit in [`jobs/requests/4-mainnet-launch.json`](../jobs/requests/4-mainnet-launch.json) (checked with `POST /requests/import`), on the `launch-mainnet` branch: `main` without `.github/workflows`, because IMD delivers the source with a token that may not create workflow files |
| Steps | `chain`: `audit-imported-code`, `adapt-contract-project`, `adversarial-review` (IMD adds tests, the manifest, four audit specialists and the judge). A launch from a repository must start with `audit-imported-code` and end with a review. |
| Contracts | `Stacker` only, `(0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7, 0x9efa934d9fad4ae28c998a40195646b965a97247)` |
| `owner` | none needed (the Stacker has no owner) |
| `ipfs` | none (a mainnet page comes later, as a `job.continue`) |
| `github` | `true` |
| `references` | `evm-contracts-launch`, `defi-native`, `eth-security`, `eth-testing`, `pashov-skill`, `solidity-security-review` |
| Prompt and request | [`jobs/4-mainnet-launch.md`](../jobs/4-mainnet-launch.md), [`jobs/requests/4-mainnet-launch.json`](../jobs/requests/4-mainnet-launch.json) |

Facts behind it (read on chain 2026-10-12, Ethereum block 26,173,849):
- **IMD** is a LayerZero OFT (`BridgedFP`): a standard 18-decimal ERC-20, no transfer fee, no pause. Its owner can only rename it and manage bridge peers.
- **sIMD** (`0x9efa…7247`): ERC-4626 over IMD, so anyone can deposit for a `receiver`. Decimals 24 (offset 6), `owner()` = 0x0 (renounced, so its pause and rescue powers are gone), `paused()` = false, about 1.81M IMD staked. One-block hold: any positive mint stamps the receiver, who can't withdraw or redeem in that block. The vault is on **Ethereum only**.
- **Mainnet fork test** of this repository's Stacker (2026-10-12): deploy 584,421 gas. `credit` to a new trader 135,735 gas (231,847 for the very first credit, which also checks and approves the vault and creates the project's totals), a repeat credit 101,535 (whole transactions, 21k base included). The previous constructor-check version measured 133,578 and 99,378 on the same fork. `test/MainnetFork.t.sol` checks the shares, the value, the one-block hold and that the Stacker keeps nothing.
- It is the same contract as the Sepolia test run 2 Stacker (launch #1294).

## Lessons from btc/acc

From TokenWorks' own write-up of [btc/acc](https://www.token.works/archive/btcacc):
- Make the hook pass Uniswap's whitelisting (the `afterSwap` logic) and support router `msgSender` and `hookData`.
- Own the main buying path. Each project's site swaps through its own hooked pool.
- Warn users about copycat v2/v3 pools.
- Fund the cashback from existing fees. Don't charge extra: apps rarely add a fee that only benefits their users.
