# Additional contract tests

These tests extend the existing suite without changing application contracts, deployment
arguments, dependencies, or Foundry configuration. All new fixtures use chain ID 11155111 and
run without a fork, network access, FFI, environment writes, or files under `test/scratch`.

| File | Properties exercised |
| --- | --- |
| `RegistryAdversarial.t.sol` | Authentication of all 15 signed fields; chain-domain separation; malformed signatures and boolean answers; exact clock-tolerance, cooldown and expiry boundaries; unrelated paid requests; replay after replacement requests; recovery from a lost callback; beneficiary handover; rollback on payment and Intake errors. |
| `RegistryAccountingInvariant.t.sol` | Random calls across three projects and five actors, with independent expected balances and listing history. Tracks exact fees, bond recipients, donations, changing prices, retired actions, unauthorized calls, failures, expiry, and request consumption. Drains pending bonds after every campaign. |
| `RegistryBodyProperties.t.sol` | Generated valid text survives JSON encoding and decoding; every forbidden byte is rejected in all three input fields before payment; minimum, maximum and adjacent invalid lengths; paid-door body, question and definition limits; Sepolia consumer domain distinct from question-routing chain. |
| `RegistryHandoffInterval.t.sol` | The one-handoff-per-day rule of `setBeneficiary`: the exact opening time at any elapsed time (fuzzed), a third wallet refused like a move back, the earlier checks (not listed, question open, not the beneficiary, zero wallet) still first, an application naming a new wallet and an expired or failed question leaving the clock alone, a per-project clock, and the property the rule buys: inside the interval a challenge naming the wallet in force is always filed and charged once (fuzzed). |
| `RegistryBondOwedInvariant.t.sol` | Owed bonds under random call sequences (test run 4's fix): a token whose refusal to pay each wallet flips at random, by reverting or returning false, while applications, challenges, signed answers delivered with 200k gas, failures, expiries and claims interleave. Ledger derived from inputs and signed outcomes only: the registry holds exactly open bonds plus owed, each wallet is owed and holds exactly its entitlement, the token is conserved, no leftover approval. A deterministic path reaches every owed outcome and both claim refusals. |
| `RegistryTryTransferEdges.t.sol` | The registry's own `transfer` read on every return shape: no return data and over-long data pay; `false`, a non-boolean word, a short word, an empty revert and a 4 KiB revert are owed and still settle within 200k. An owed bond is settled once (replayed answer, late failure, expire, consumed request id); survives relisting and later payouts; only the creditor claims; a failed claim keeps the debt; a claim never touches an open bond. |
| `StackerExternalCalls.t.sol` | Late vault errors and zero-share returns roll back actual transfers and mints; token reentrancy is rejected at approval and transfer boundaries; optional ERC-20 return data; isolation of caller allowances; differential comparison with a direct vault deposit from identical state. |

New fuzz tests use 1,000 runs. The accounting invariant uses 256 runs of depth 64 with
`fail-on-revert` enabled and an explicit selector list. Valid callbacks must succeed: an
unexpected callback failure is an assertion failure, rather than a silently discarded action.
A deterministic handler test exercises all payout outcomes and checks the model between
transitions. The existing Stacker value-conservation invariants and protocol signature-vector
tests remain in the suite.

The accounting model also tracks beneficiary pinning independently across handoffs and
relistings. Random calls attempt handoffs during open challenges, stale beneficiary pins,
and legacy challenges after a handoff, checking the precise rejection and unchanged ledger.
Deterministic campaigns cover returning to the original beneficiary and oracle retirement
after a handoff. Settlement tests verify each defended bond reaches the beneficiary named
when that challenge opened.

Run the full local checks with:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

The output overrides keep generated artifacts inside the permitted scratch directory; they
are not required for the tests. Ordinary `forge test` uses the same tests and inline settings.

These checks exercise the application code against local token, vault and Intake fixtures.
They do not establish the current state of live Sepolia dependencies or prove that an off-chain
oracle panel will accept a question. Existing optional fork tests skip when their RPC settings
are absent. No new test skips or needs RPC configuration.
