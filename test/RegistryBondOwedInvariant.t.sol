// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation} from "src/oracle/OracleAttestation.sol";
import {MockIntake, MockProject} from "./mocks/MockIntake.sol";

/// @dev An oracle asset whose refusal to pay a wallet can be switched on and off at any time, in
/// either of the two shapes a real token has: a revert, or `false` with nothing moved.
contract RefusingIMD is ERC20 {
    uint8 public constant PAYS = 0;
    uint8 public constant REVERTS = 1;
    uint8 public constant RETURNS_FALSE = 2;

    mapping(address => uint8) public mode;

    constructor() ERC20("Refusing IMD", "rIMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(address who, uint8 m) external {
        mode[who] = m;
    }

    function refuses(address to) public view returns (bool) {
        return mode[to] != PAYS;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (mode[to] == RETURNS_FALSE) return false;
        return super.transfer(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(mode[to] != REVERTS, "refused");
        super._update(from, to, value);
    }
}

/// @dev Drives the registry through random applications, challenges, signed answers, failures,
/// expiries and claims while the token's refusal to pay each actor flips at random. The ledger
/// it keeps is derived from inputs and signed outcomes only: who posted which bond, who the
/// signed answer entitles to it, and whether the token was refusing that wallet at that moment.
/// Every call is guarded so the handler never reverts (fail_on_revert is on).
contract BondOwedHandler is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 public constant BOND = 5e18;
    uint256 public constant FEE = 0.5e18;
    uint256 public constant INITIAL = 1_000e18;
    uint256 public constant CALLBACK_GAS = 200_000;

    ProjectRegistry public immutable reg;
    MockIntake public immutable intake;
    RefusingIMD public immutable imd;
    address[4] public actors;
    address[3] public projects;

    /// @dev What each actor should hold in the token, and what the registry should owe them.
    mapping(address => uint256) public expectedFunds;
    mapping(address => uint256) public expectedOwed;
    uint256 public openBonds;
    uint256 public totalOwed;
    uint256 public feesPaid;

    uint256 public owedByDelisting;
    uint256 public owedByDefence;
    uint256 public owedByFailure;
    uint256 public owedByExpiry;
    uint256 public paidAtOnce;
    uint256 public claimsPaid;
    uint256 public claimsRefused;
    uint256 public claimsOfNothing;
    uint256 public listings;
    uint256 internal uuid;

    constructor(ProjectRegistry reg_, MockIntake intake_, RefusingIMD imd_) {
        reg = reg_;
        intake = intake_;
        imd = imd_;
        for (uint256 i; i < actors.length; ++i) {
            address a = makeAddr(string.concat("owed actor ", vm.toString(i)));
            actors[i] = a;
            imd.mint(a, INITIAL);
            expectedFunds[a] = INITIAL;
            vm.prank(a);
            imd.approve(address(reg), type(uint256).max);
        }
        for (uint256 i; i < projects.length; ++i) {
            projects[i] = address(new MockProject());
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function projectCount() external view returns (uint256) {
        return projects.length;
    }

    // ------------------------------------------------------------ actions

    function setRefusal(uint256 aSeed, uint8 mode) external {
        imd.setMode(actors[aSeed % actors.length], uint8(bound(mode, 0, 2)));
    }

    function passTime(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
        vm.roll(block.number + 1);
    }

    function applyFor(uint256 pSeed, uint256 aSeed, uint256 bSeed, uint16 rate) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (s.ask != ProjectRegistry.Ask.None || s.listed) return;
        address applicant = actors[aSeed % actors.length];
        address beneficiary = actors[bSeed % actors.length];
        vm.prank(applicant);
        reg.applyListing(
            p, "Project", "https://example.org/source", uint16(bound(rate, 25, 100)), beneficiary
        );
        expectedFunds[applicant] -= FEE;
        feesPaid += FEE;
    }

    function challengeFor(uint256 pSeed, uint256 aSeed) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (!s.listed || s.ask != ProjectRegistry.Ask.None) return;
        if (block.timestamp < s.challengeOpenAt) vm.warp(s.challengeOpenAt);
        address challenger = actors[aSeed % actors.length];
        vm.prank(challenger);
        reg.challengeForBeneficiary(p, "Review.", s.beneficiary);
        expectedFunds[challenger] -= FEE + BOND;
        feesPaid += FEE;
        openBonds++;
    }

    /// @dev Plays the writer: a signed answer delivered with the mainnet callback budget. A
    /// valid answer must always land, whatever the token thinks of the bond's recipient.
    function answer(uint256 pSeed, bool yes) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (s.ask == ProjectRegistry.Ask.None) return;
        if (block.timestamp > uint256(s.askedAt) + reg.PENDING_EXPIRY()) return;

        OracleAttestation.Attestation memory a;
        a.requestId = bytes32(++uuid << 128);
        a.chainId = 1;
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(SIGNER_KEY, reg.attestationDigest(a));

        bool delivered = intake.deliver(s.intakeId, a, abi.encodePacked(r, sg, v), CALLBACK_GAS);
        assertTrue(delivered, "a valid answer settles within the callback budget");

        if (s.ask == ProjectRegistry.Ask.Apply) {
            if (yes) listings++;
            return;
        }
        if (yes) {
            if (_bondSettled(s.beneficiary)) owedByDefence++;
        } else {
            if (_bondSettled(s.asker)) owedByDelisting++;
        }
    }

    function failFor(uint256 pSeed, uint8 status) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (s.ask == ProjectRegistry.Ask.None) return;
        bool delivered =
            intake.fail(s.intakeId, uint8(bound(status, 1, 2)), bytes32("disagreed"), CALLBACK_GAS);
        assertTrue(delivered, "a failure clears within the callback budget");
        if (s.ask == ProjectRegistry.Ask.Challenge && _bondSettled(s.asker)) owedByFailure++;
    }

    function expireFor(uint256 pSeed, bool silently) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (s.ask == ProjectRegistry.Ask.None) return;
        if (silently) {
            intake.completeSilently(s.intakeId);
        } else if (block.timestamp <= uint256(s.askedAt) + reg.PENDING_EXPIRY()) {
            vm.warp(uint256(s.askedAt) + reg.PENDING_EXPIRY() + 1);
        }
        vm.prank(actors[0]);
        reg.expire(p);
        if (s.ask == ProjectRegistry.Ask.Challenge && _bondSettled(s.asker)) owedByExpiry++;
    }

    /// @dev An actor takes what it is owed, to itself or to another wallet. The token may refuse
    /// the destination too; then nothing changes.
    function claim(uint256 aSeed, uint256 toSeed) external {
        address who = actors[aSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 owed = expectedOwed[who];
        vm.prank(who);
        try reg.claimBond(to) {
            assertGt(owed, 0, "claimed with nothing owed");
            assertFalse(imd.refuses(to), "claimed to a wallet the token refuses");
            expectedOwed[who] = 0;
            totalOwed -= owed;
            expectedFunds[to] += owed;
            claimsPaid++;
        } catch (bytes memory err) {
            if (owed == 0) {
                assertEq(bytes4(err), ProjectRegistry.NothingOwed.selector, "wrong refusal");
                claimsOfNothing++;
            } else {
                assertTrue(imd.refuses(to), "a paying token refused a claim");
                claimsRefused++;
            }
        }
    }

    /// @dev One bond left the open set for `to`: owed if the token refuses that wallet right
    /// now, paid otherwise. Returns whether it was owed.
    function _bondSettled(address to) internal returns (bool refused) {
        openBonds--;
        refused = imd.refuses(to);
        if (refused) {
            expectedOwed[to] += BOND;
            totalOwed += BOND;
        } else {
            expectedFunds[to] += BOND;
            paidAtOnce++;
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
/// @dev Owed bonds under random call sequences: whatever the token refuses, the registry holds
/// exactly the open bonds plus what it owes, each wallet is owed exactly the bonds the signed
/// outcomes entitle it to, and nobody ends up with more than their entitlement.
contract RegistryBondOwedInvariantTest is StdInvariant, Test {
    uint256 internal constant BOND = 5e18;

    ProjectRegistry internal reg;
    MockIntake internal intake;
    RefusingIMD internal imd;
    BondOwedHandler internal handler;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        intake = new MockIntake();
        imd = new RefusingIMD();
        reg = new ProjectRegistry(
            address(intake), address(imd), address(0x57AC), vm.addr(0xA11CE), 1, BOND, 1 hours
        );
        handler = new BondOwedHandler(reg, intake, imd);
        targetContract(address(handler));
    }

    /// @notice The registry holds exactly the open challenge bonds plus every bond it owes.
    function invariant_holdsOpenBondsPlusOwed() public view {
        uint256 open;
        for (uint256 i; i < handler.projectCount(); ++i) {
            if (reg.projectOf(handler.projects(i)).ask == ProjectRegistry.Ask.Challenge) open++;
        }
        assertEq(open, handler.openBonds(), "open challenges");
        assertEq(
            imd.balanceOf(address(reg)),
            open * BOND + handler.totalOwed(),
            "registry holds open bonds plus owed"
        );
        assertEq(imd.allowance(address(reg), address(intake)), 0, "no leftover approval");
    }

    /// @notice Each wallet is owed and holds exactly what the signed outcomes entitle it to.
    function invariant_eachWalletOwedAndPaidExactly() public view {
        uint256 owedSum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(reg.bondOwed(a), handler.expectedOwed(a), "owed");
            assertEq(imd.balanceOf(a), handler.expectedFunds(a), "held");
            owedSum += reg.bondOwed(a);
        }
        assertEq(owedSum, handler.totalOwed(), "owed sums");
    }

    /// @notice Nothing is created or lost: actors' balances, the Intake's fees, the open bonds
    /// and the owed bonds add up to what was minted.
    function invariant_tokenConserved() public view {
        uint256 actorsHold;
        for (uint256 i; i < handler.actorCount(); ++i) {
            actorsHold += imd.balanceOf(handler.actors(i));
        }
        assertEq(
            actorsHold + imd.balanceOf(intake.TREASURY()) + imd.balanceOf(address(reg)),
            handler.actorCount() * handler.INITIAL(),
            "supply"
        );
        assertEq(imd.balanceOf(intake.TREASURY()), handler.feesPaid(), "fees reached the Intake");
    }

    /// @notice A fixed path reaching every owed outcome and both claim refusals, so the random
    /// campaign is known to reach them and the model is checked between each transition.
    function test_handlerReachesEveryOwedOutcome() public {
        // Project 0 listed; the challenger (actor 1) is blocked when the "no" lands: owed.
        handler.applyFor(0, 0, 2, 50);
        handler.answer(0, true);
        handler.challengeFor(0, 1);
        handler.setRefusal(1, 1);
        handler.answer(0, false);
        assertEq(handler.owedByDelisting(), 1);
        _check();

        // Relist; the beneficiary (actor 2) returns false when the "yes" lands: owed.
        handler.applyFor(0, 0, 2, 50);
        handler.answer(0, true);
        handler.challengeFor(0, 3);
        handler.setRefusal(2, 2);
        handler.answer(0, true);
        assertEq(handler.owedByDefence(), 1);
        _check();

        // A failure and an expiry with the challenger blocked.
        handler.challengeFor(0, 1);
        handler.failFor(0, 2);
        assertEq(handler.owedByFailure(), 1);
        handler.challengeFor(0, 1);
        handler.expireFor(0, false);
        assertEq(handler.owedByExpiry(), 1);
        handler.challengeFor(0, 1);
        handler.expireFor(0, true);
        assertEq(handler.owedByExpiry(), 2);
        assertEq(reg.bondOwed(handler.actors(1)), 4 * BOND);
        _check();

        // Claims: to a refused wallet (nothing changes), of nothing (refused), then to a wallet
        // the token pays.
        handler.claim(1, 1);
        assertEq(handler.claimsRefused(), 1);
        handler.claim(0, 0);
        assertEq(handler.claimsOfNothing(), 1);
        handler.claim(1, 0);
        handler.claim(2, 3);
        assertEq(handler.claimsPaid(), 2);
        assertEq(reg.bondOwed(handler.actors(1)), 0);
        assertEq(reg.bondOwed(handler.actors(2)), 0);
        _check();

        // An unblocked challenger is paid at once, as before the fix.
        handler.setRefusal(1, 0);
        handler.challengeFor(0, 1);
        handler.answer(0, false);
        assertEq(handler.paidAtOnce(), 1);
        _check();
        assertEq(imd.balanceOf(address(reg)), 0, "nothing left once everything is claimed");
    }

    function _check() internal view {
        invariant_holdsOpenBondsPlusOwed();
        invariant_eachWalletOwedAndPaidExactly();
        invariant_tokenConserved();
    }
}
