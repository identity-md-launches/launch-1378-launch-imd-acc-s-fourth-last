// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProjectRegistry, IIntake} from "src/ProjectRegistry.sol";
import {OracleAttestation} from "src/oracle/OracleAttestation.sol";

/// @dev An oracle asset that refuses transfers to blocked wallets: by reverting, or (with
/// `returnFalse`) by returning false without moving anything.
contract BlocklistIMD is ERC20 {
    mapping(address => bool) public blocked;
    bool public returnFalse;

    constructor() ERC20("Blocklist IMD", "bIMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool on) external {
        blocked[who] = on;
    }

    function setReturnFalse(bool on) external {
        returnFalse = on;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (returnFalse && blocked[to]) return false;
        return super.transfer(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// @dev Intake stand-in that delivers answers and failures with exactly 200k gas, like mainnet.
contract GasCappedIntake is IIntake {
    bytes32 internal constant ACTION = "oracle.request@oracle-1";

    struct Req {
        address target;
        bytes4 selector;
        bytes4 onFailure;
        bool completed;
    }

    mapping(bytes32 => Req) internal reqs;
    uint256 internal n;

    function priceOf(bytes32 action, address) external pure returns (uint256) {
        return action == ACTION ? 0.5e18 : 0;
    }

    function requestWithFailure(
        bytes32,
        bytes calldata,
        Callback calldata cb,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        IERC20(asset).transferFrom(msg.sender, address(0x7EA5), amount);
        id = keccak256(abi.encode(++n));
        reqs[id] = Req(cb.target, cb.selector, onFailure, false);
    }

    function requests(bytes32 id) external view returns (address, address, bytes4, bool) {
        return (address(0), reqs[id].target, reqs[id].selector, reqs[id].completed);
    }

    function deliver(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata sig)
        external
        returns (bool ok)
    {
        reqs[id].completed = true;
        (ok,) = reqs[id].target.call{gas: 200_000}(
            abi.encodeWithSelector(reqs[id].selector, id, a, sig)
        );
    }

    function fail(bytes32 id, uint8 status, bytes32 reason) external returns (bool ok) {
        reqs[id].completed = true;
        (ok,) = reqs[id].target.call{gas: 200_000}(
            abi.encodeWithSelector(reqs[id].onFailure, id, status, reason, 15, 0, "")
        );
    }
}

contract SomeProject {}

/// @dev A bond the oracle asset refuses to pay never holds a question open (Sepolia test run 3's
/// judged low, from IMD's proof): the question settles or clears, the bond is recorded in
/// `bondOwed`, and its recipient takes it with `claimBond`, to another wallet if need be.
contract RegistryBondOwedTest is Test {
    uint256 internal constant KEY = 0xA11CE;
    uint256 internal constant BOND = 5e18;

    GasCappedIntake internal intake;
    BlocklistIMD internal imd;
    ProjectRegistry internal reg;
    address internal project;
    address internal applicant = makeAddr("applicant");
    address internal challenger = makeAddr("challenger");
    address internal beneficiary = makeAddr("beneficiary");
    address internal otherWallet = makeAddr("otherWallet");
    uint256 internal uuid;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);
        intake = new GasCappedIntake();
        imd = new BlocklistIMD();
        reg = new ProjectRegistry(
            address(intake), address(imd), address(0x57AC), vm.addr(KEY), 1, BOND, 1 hours
        );
        project = address(new SomeProject());
        imd.mint(applicant, 100e18);
        imd.mint(challenger, 100e18);
        vm.prank(applicant);
        imd.approve(address(reg), type(uint256).max);
        vm.prank(challenger);
        imd.approve(address(reg), type(uint256).max);
    }

    function _att(bool yes) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++uuid << 128);
        a.chainId = 1;
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sig(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, reg.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _listAndChallenge() internal returns (bytes32 id) {
        vm.prank(applicant);
        id = reg.applyListing(project, "P", "https://x.example/p", 50, beneficiary);
        OracleAttestation.Attestation memory a = _att(true);
        assertTrue(intake.deliver(id, a, _sig(a)));
        assertTrue(reg.isListed(project));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(challenger);
        id = reg.challengeForBeneficiary(project, "Review.", beneficiary);
        assertEq(imd.balanceOf(address(reg)), BOND, "bond held");
    }

    function _assertSlotFree() internal view {
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None), "slot cleared");
    }

    /// IMD's proof, settled: a signed "no" to a blocked challenger's challenge delists the project
    /// within the 200k callback budget; the bond is owed, and claimed to another wallet.
    function test_blockedChallenger_signedNo_delistsAndOwesBond() public {
        bytes32 id = _listAndChallenge();
        imd.setBlocked(challenger, true);

        vm.expectEmit(address(reg));
        emit ProjectRegistry.BondOwed(challenger, BOND);
        OracleAttestation.Attestation memory a = _att(false);
        assertTrue(intake.deliver(id, a, _sig(a)), "settled within 200k");

        assertFalse(reg.isListed(project), "delisted");
        _assertSlotFree();
        assertEq(reg.bondOwed(challenger), BOND);
        assertEq(imd.balanceOf(address(reg)), BOND, "the owed bond stays in the registry");

        vm.prank(challenger);
        vm.expectRevert("blocked");
        reg.claimBond(challenger);

        vm.expectEmit(address(reg));
        emit ProjectRegistry.BondClaimed(challenger, otherWallet, BOND);
        vm.prank(challenger);
        reg.claimBond(otherWallet);
        assertEq(imd.balanceOf(otherWallet), BOND);
        assertEq(reg.bondOwed(challenger), 0);
        assertEq(imd.balanceOf(address(reg)), 0);

        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.NothingOwed.selector);
        reg.claimBond(otherWallet);
    }

    /// A refused or split question still clears when the token blocks the challenger.
    function test_blockedChallenger_failureClearsAndOwesBond() public {
        bytes32 id = _listAndChallenge();
        imd.setBlocked(challenger, true);

        assertTrue(intake.fail(id, 2, bytes32("disagreed")), "failure within 200k");
        _assertSlotFree();
        assertTrue(reg.isListed(project), "a failure never delists");
        assertEq(reg.bondOwed(challenger), BOND);

        // The project can be challenged again at once.
        vm.prank(applicant);
        reg.challengeForBeneficiary(project, "Again.", beneficiary);
    }

    /// A question nobody answers can still be expired after a day, by anyone.
    function test_blockedChallenger_expireClearsAndOwesBond() public {
        _listAndChallenge();
        imd.setBlocked(challenger, true);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(makeAddr("anyone"));
        reg.expire(project);
        _assertSlotFree();
        assertEq(reg.bondOwed(challenger), BOND);
    }

    /// A defended challenge is applied even when the token blocks the beneficiary; the bond is
    /// owed to the beneficiary, not sent back to the challenger.
    function test_blockedBeneficiary_signedYes_defendsAndOwesBond() public {
        bytes32 id = _listAndChallenge();
        imd.setBlocked(beneficiary, true);

        OracleAttestation.Attestation memory a = _att(true);
        assertTrue(intake.deliver(id, a, _sig(a)), "settled within 200k");
        assertTrue(reg.isListed(project), "still listed");
        _assertSlotFree();
        assertEq(reg.bondOwed(beneficiary), BOND);
        assertEq(reg.bondOwed(challenger), 0);

        vm.prank(beneficiary);
        reg.claimBond(otherWallet);
        assertEq(imd.balanceOf(otherWallet), BOND);
    }

    /// A token that returns false instead of reverting is treated the same way.
    function test_falseReturningToken_owesBond() public {
        bytes32 id = _listAndChallenge();
        imd.setBlocked(challenger, true);
        imd.setReturnFalse(true);

        OracleAttestation.Attestation memory a = _att(false);
        assertTrue(intake.deliver(id, a, _sig(a)));
        assertFalse(reg.isListed(project));
        assertEq(reg.bondOwed(challenger), BOND);
        assertEq(imd.balanceOf(address(reg)), BOND);
    }

    /// When the token pays, nothing is owed: the bond moves at settlement as before.
    function test_unblocked_paysAtOnce() public {
        bytes32 id = _listAndChallenge();
        uint256 before = imd.balanceOf(challenger);
        OracleAttestation.Attestation memory a = _att(false);
        assertTrue(intake.deliver(id, a, _sig(a)));
        assertEq(imd.balanceOf(challenger), before + BOND);
        assertEq(reg.bondOwed(challenger), 0);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    /// Owed bonds add up across questions and are claimed once.
    function test_owedBondsAccumulate() public {
        bytes32 id = _listAndChallenge();
        imd.setBlocked(challenger, true);
        assertTrue(intake.fail(id, 1, bytes32("body_refused")));
        imd.setBlocked(challenger, false);
        vm.prank(challenger);
        id = reg.challengeForBeneficiary(project, "Again.", beneficiary);
        imd.setBlocked(challenger, true);
        assertTrue(intake.fail(id, 2, bytes32("disagreed")));

        assertEq(reg.bondOwed(challenger), 2 * BOND);
        assertEq(imd.balanceOf(address(reg)), 2 * BOND);
        vm.prank(challenger);
        reg.claimBond(otherWallet);
        assertEq(imd.balanceOf(otherWallet), 2 * BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_claimBond_refusesZeroAddressAndNothingOwed() public {
        vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        reg.claimBond(address(0));
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.NothingOwed.selector);
        reg.claimBond(challenger);
    }
}
