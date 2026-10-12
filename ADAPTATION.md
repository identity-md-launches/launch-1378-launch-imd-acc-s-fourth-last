# Adaptation notes: Sepolia test run 4 (the ProjectRegistry alone)

This launch deploys one contract, `ProjectRegistry`, from the `launch-sepolia` branch, wired to test
run 2's live Stacker (`0x0457276d7b036818b3eddc1a4a3fceda61e9314d`), IdentityMD's Intake v2
(`0xa43e6f75ee006411f79ac1c84120606c2330de82`), the Sepolia test IMD
(`0x44a1cd38474fb1748400e7deb5f8d786cce3f89a`) and the oracle signer
(`0x5598aa9146215bc13eb26f2c692ad1461fd32982`), with questions filed under chain 1, a 5 test-IMD
challenge bond and a 3600-second cooldown. `launch.json` was already in the tree with exactly these
arguments and is left as it is; the manifest step owns it.

## What the launch rules required

Nothing in `src/` had to change. The code as it arrived already meets every launch rule:

| Rule | Where it holds |
|---|---|
| A nonpayable constructor with static argument types, at most 16 arguments, no external call, no address required to have code | `src/ProjectRegistry.sol`, constructor: 7 arguments (4 addresses, 3 unsigned integers); it stores them and checks ranges only. `test/Deployment.t.sol` deploys it on an empty chain. |
| No owner handed to the factory (`msg.sender`) or to IMD (`tx.origin`) | The registry has no owner or admin role at all; the oracle panel decides. |
| No minting, pausing, freezing, seizing, DELEGATECALL, CALLCODE, SELFDESTRUCT, proxies or upgradeability | None are present. `test/Deployment.t.sol` scans the runtime for the three forbidden opcodes and checks its size (22,736 bytes, under EIP-170). |
| Every library function called is internal | `OracleAttestation` and OpenZeppelin's `SafeERC20` / `Strings` are internal-only; the bytecode links nothing. |
| Build configuration untouched | `foundry.toml` (solc 0.8.26, cancun, 10,000 runs, `bytecode_hash = "none"`), `remappings.txt` and `lib/` are unchanged. |
| No workflow file | `.github/` holds only an issue template; none was added. |

The fix the brief asks for, test run 3's judged low (a bond the oracle asset refuses to pay no
longer holds a question open: `bondOwed`, `BondOwed`, `claimBond(to)`), is already in
`src/ProjectRegistry.sol` on this branch and covered by `test/RegistryBondOwed.t.sol`. The handoff
rule (`HANDOFF_INTERVAL`, `HandoffTooSoon`) is in place and covered by
`test/RegistryHandoffInterval.t.sol` and `test/RegistryRevisionRegression.t.sol`.

## The import audit's findings

Both low findings were reproduced against the mock Intake exactly as the audit describes them, and
neither changes the contract. They are the same limit seen from two sides: a project holds one open
question at a time, and anyone may ask it.

### 77a0dce2 (low): the beneficiary front-runs outside challenges with a self-challenge

Reproduced: `test/RegistryAuditLows.t.sol`, `test_selfChallengeCycleCostsOnlyTheFeeAndNeverRenewsImmunity`.
Three cycles: the beneficiary files first, the outsider reverts `AskOpen` and pays nothing, the
panel says yes, the bond returns to the beneficiary, net cost three oracle fees.

Not fixed, for these reasons:

- The requester decided this in test run 3's audit, where the same finding was raised, disputed and
  accepted by the judge as a design limit (`docs/history.md`, section 22: "a beneficiary's own
  challenge can take the single slot for the fee alone (low; it still puts the project before the
  panel)"). `test/RegistryRevisionRegression.t.sol` already pins it as a retained limit.
- The mitigations the audit offers do not close it within the agreed design. Paying a defended bond
  to the beneficiary only when the challenger is not the beneficiary, or rate-limiting the
  beneficiary's wallet, is bypassed by any second wallet the beneficiary controls, which the finding
  itself notes. Only forfeiting every defended bond would make a self-challenge cost the bond, and
  the brief fixes the defended bond's destination ("bond to its beneficiary").
- What the limit cannot do is tested: the cooldown does not restart, so an outsider files the
  moment the self-challenge settles; the panel still judges the project against all eight rules on
  every self-challenge, and a signed no delists it and returns the bond.

### cfc4bf3a (low): a doomed application occupies the slot

Reproduced: `test/RegistryAuditLows.t.sol`, `test_doomedApplicationHoldsTheSlotOnlyUntilAnsweredAndNeverLists`.
Three rounds: a stranger applies with itself as beneficiary, the owner's application reverts
`AskOpen` without paying, the panel says no, the slot is free in the same block.

Not fixed, for these reasons:

- It is a documented, accepted limit of open applications (`docs/design.md`, "Known limits",
  "Blocking by spam"), already pinned by `test/RegistryAuditRegression.t.sol`
  (`test_permissionlessApplicantCanOccupySlotUntilRejected`).
- The mitigations the audit offers do not close it within the agreed design. A re-application
  cooldown after a rejection also locks out the project's own team and only slows the stranger's
  cadence; restricting re-application to "the beneficiary the project's owner names" needs a notion
  of project owner the registry deliberately does not have (no owner role; the panel's beneficiary
  rule decides who may hold the points).
- Each round costs the stranger the oracle fee and a panel, never lists the stranger (the panel
  checks the beneficiary rule), and once the project is listed the slot can no longer be taken
  (`AlreadyListed`), which the test checks.

### c6b02bf6 (info): coverage

No action. The measurements it reports (question and definition lengths, body size, runtime size,
selectors, manifest shape) match this tree.

## Other files changed

- `test/RegistryAuditLows.t.sol` (new): the two reproductions above. The suite is now 182 tests,
  174 offline and 8 forks.
- `README.md`: a "Sepolia test run 4" entry in the Deployments table, with the address to be filled
  in once the launch is live (the registry's address is only known after deployment, so none is
  written now), and the test count.
- `ADAPTATION.md` (this file).

## Checks run

`forge build` (solc 0.8.26, cancun, 10,000 runs, `bytecode_hash = "none"`) and `forge test` with
an empty environment: 174 passed, 0 failed, 8 skipped (the fork tests, which need `ETH_RPC_URL` and
`SEPOLIA_RPC_URL`). This worker had no RPC, so the live Intake, test IMD and Stacker were not read
here; the brief's facts (Sepolia block 11,897,397) and `test/RegistrySepoliaFork.t.sol` stand for
them.
