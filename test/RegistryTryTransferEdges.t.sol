// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/oracle/OracleAttestation.sol";
import {MockIntake, MockProject} from "./mocks/MockIntake.sol";

/// @dev An oracle asset whose `transfer` answers in whatever shape a test picks, so the registry's
/// own `transfer` call (which must read return data the way SafeERC20 does) is judged on each.
/// Shapes that move the tokens return something a careful caller accepts; shapes that refuse move
/// nothing.
contract ShapedIMD is ERC20 {
    enum Shape {
        True, // the ERC-20 standard: 32 bytes, 1
        NoReturn, // USDT style: moves the tokens, returns nothing
        LongReturn, // moves the tokens, returns 64 bytes whose first word is 1
        False, // refuses: 32 bytes, 0
        Two, // refuses: 32 bytes, 2 (not a boolean)
        Short, // refuses: one byte, 0x01
        RevertEmpty, // refuses: revert with no data
        RevertLong // refuses: revert with 4 KiB of reason
    }

    Shape public shape;

    constructor() ERC20("Shaped IMD", "sIMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setShape(Shape s) external {
        shape = s;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        Shape s = shape;
        if (s == Shape.True) return super.transfer(to, value);
        if (s == Shape.NoReturn) {
            super.transfer(to, value);
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (s == Shape.LongReturn) {
            super.transfer(to, value);
            bytes memory out = abi.encode(uint256(1), uint256(7));
            assembly ("memory-safe") {
                return(add(out, 0x20), mload(out))
            }
        }
        if (s == Shape.False) return false;
        if (s == Shape.Two) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 0x20)
            }
        }
        if (s == Shape.Short) {
            assembly ("memory-safe") {
                mstore8(0, 1)
                return(0, 1)
            }
        }
        if (s == Shape.RevertEmpty) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        bytes memory reason = new bytes(4096);
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}

/// @dev The one place the registry reads a token's answer itself (`_tryTransfer`, the owed-bond
/// path) is judged on every return shape, and the owed record is shown to be settled once only:
/// no answer, failure, expiry or replay can count the same bond twice.
contract RegistryTryTransferEdgesTest is Test {
    uint256 internal constant KEY = 0xA11CE;
    uint256 internal constant BOND = 5e18;
    uint256 internal constant FEE = 0.5e18;
    uint256 internal constant CALLBACK_GAS = 200_000;

    MockIntake internal intake;
    ShapedIMD internal imd;
    ProjectRegistry internal reg;
    address internal project;
    address internal applicant = makeAddr("applicant");
    address internal challenger = makeAddr("challenger");
    address internal beneficiary = makeAddr("beneficiary");
    address internal other = makeAddr("other");
    uint256 internal uuid;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        intake = new MockIntake();
        imd = new ShapedIMD();
        reg = new ProjectRegistry(
            address(intake), address(imd), address(0x57AC), vm.addr(KEY), 1, BOND, 1 hours
        );
        project = address(new MockProject());
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
        a.answerType = OracleAttestation.ANSWER_BOOL;
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

    function _deliver(bytes32 id, bool yes) internal returns (bool) {
        OracleAttestation.Attestation memory a = _att(yes);
        return intake.deliver(id, a, _sig(a), CALLBACK_GAS);
    }

    function _listAndChallenge() internal returns (bytes32 id) {
        vm.prank(applicant);
        id = reg.applyListing(project, "P", "https://x.example/p", 50, beneficiary);
        assertTrue(_deliver(id, true));
        assertTrue(reg.isListed(project));
        vm.warp(block.timestamp + 1 hours);
        uint256 held = imd.balanceOf(address(reg));
        vm.prank(challenger);
        id = reg.challengeForBeneficiary(project, "Review.", beneficiary);
        assertEq(imd.balanceOf(address(reg)), held + BOND, "the new bond is held");
    }

    // ------------------------------------------------------------ return shapes

    /// A signed "no" with each paying shape: the bond reaches the challenger at once and nothing
    /// is owed. A token that returns nothing, or more than a word, is still a payment.
    function test_payingShapes_bondPaidAtOnce() public {
        ShapedIMD.Shape[3] memory paying =
            [ShapedIMD.Shape.True, ShapedIMD.Shape.NoReturn, ShapedIMD.Shape.LongReturn];
        for (uint256 i; i < paying.length; ++i) {
            bytes32 id = _listAndChallenge();
            imd.setShape(paying[i]);
            uint256 before = imd.balanceOf(challenger);
            assertTrue(_deliver(id, false), "settled within 200k");
            imd.setShape(ShapedIMD.Shape.True);
            assertFalse(reg.isListed(project), "delisted");
            assertEq(imd.balanceOf(challenger), before + BOND, "paid at once");
            assertEq(reg.bondOwed(challenger), 0, "nothing owed");
            assertEq(imd.balanceOf(address(reg)), 0, "registry empty");
        }
    }

    /// A signed "no" with each refusing shape: the project is still delisted within the callback
    /// budget, the bond is owed, the tokens stay in the registry, and nothing else was paid out.
    function test_refusingShapes_bondOwedAndQuestionSettles() public {
        ShapedIMD.Shape[5] memory refusing = [
            ShapedIMD.Shape.False,
            ShapedIMD.Shape.Two,
            ShapedIMD.Shape.Short,
            ShapedIMD.Shape.RevertEmpty,
            ShapedIMD.Shape.RevertLong
        ];
        for (uint256 i; i < refusing.length; ++i) {
            bytes32 id = _listAndChallenge();
            imd.setShape(refusing[i]);
            uint256 before = imd.balanceOf(challenger);
            vm.expectEmit(address(reg));
            emit ProjectRegistry.BondOwed(challenger, BOND);
            assertTrue(_deliver(id, false), "settled within 200k despite the refusal");
            assertFalse(reg.isListed(project), "delisted");
            assertEq(imd.balanceOf(challenger), before, "nothing moved");
            assertEq(reg.bondOwed(challenger), BOND, "owed");
            assertEq(imd.balanceOf(address(reg)), BOND, "bond still held");

            imd.setShape(ShapedIMD.Shape.True);
            vm.prank(challenger);
            reg.claimBond(challenger);
            assertEq(imd.balanceOf(challenger), before + BOND, "claimed once the token pays");
            assertEq(imd.balanceOf(address(reg)), 0);
        }
    }

    /// The same refusing shapes on the defended path: the beneficiary is owed, the challenger is
    /// not, and the listing stays with its cooldown untouched.
    function test_refusingShapes_defendedBondOwedToBeneficiary() public {
        ShapedIMD.Shape[3] memory refusing =
            [ShapedIMD.Shape.Two, ShapedIMD.Shape.Short, ShapedIMD.Shape.RevertLong];
        for (uint256 i; i < refusing.length; ++i) {
            bytes32 id = _listAndChallenge();
            uint64 openAt = reg.projectOf(project).challengeOpenAt;
            imd.setShape(refusing[i]);
            assertTrue(_deliver(id, true), "settled within 200k");
            imd.setShape(ShapedIMD.Shape.True);
            assertTrue(reg.isListed(project), "kept");
            assertEq(reg.projectOf(project).challengeOpenAt, openAt, "cooldown not restarted");
            assertEq(reg.bondOwed(beneficiary), BOND * (i + 1), "owed to the beneficiary");
            assertEq(reg.bondOwed(challenger), 0, "not to the challenger");
            // Leave the project unlisted for the next round.
            vm.prank(challenger);
            id = reg.challengeForBeneficiary(project, "Again.", beneficiary);
            assertTrue(_deliver(id, false));
        }
        vm.prank(beneficiary);
        reg.claimBond(other);
        assertEq(imd.balanceOf(other), 3 * BOND);
    }

    /// The transfer the registry reports on is given its answer once: a token that refuses while
    /// a challenge is open and pays again before the answer lands owes nothing.
    function test_refusalLiftedBeforeAnswer_paysAtOnce() public {
        bytes32 id = _listAndChallenge();
        imd.setShape(ShapedIMD.Shape.RevertEmpty);
        imd.setShape(ShapedIMD.Shape.True);
        assertTrue(_deliver(id, false));
        assertEq(reg.bondOwed(challenger), 0);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    // ------------------------------------------------------------ settled once

    /// Once a refused bond is owed, nothing can count it again: the same id is unknown to the
    /// callback and to the failure function, there is nothing to expire, and the attestation's
    /// request id is consumed.
    function test_owedBondIsSettledOnce() public {
        bytes32 id = _listAndChallenge();
        imd.setShape(ShapedIMD.Shape.False);
        OracleAttestation.Attestation memory a = _att(false);
        bytes memory sig = _sig(a);
        assertTrue(intake.deliver(id, a, sig, CALLBACK_GAS));
        assertEq(reg.bondOwed(challenger), BOND);

        // Replayed answer: the Intake's id is no longer open.
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, id));
        reg.onOracleResult(id, a, sig);

        // A late failure for the same id.
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, id));
        reg.onOracleFailure(id, 2, "disagreed", 0, 0, "");

        // Nothing to expire, by anyone, now or a day later.
        vm.expectRevert(ProjectRegistry.NothingToExpire.selector);
        reg.expire(project);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(ProjectRegistry.NothingToExpire.selector);
        reg.expire(project);

        // The oracle's request id is consumed: a new question cannot be settled with it.
        imd.setShape(ShapedIMD.Shape.True);
        vm.prank(applicant);
        bytes32 id2 = reg.applyListing(project, "P", "https://x.example/p", 50, beneficiary);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        a.answer = abi.encode(true);
        sig = _sig(a);
        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId)
        );
        reg.onOracleResult(id2, a, sig);

        assertEq(reg.bondOwed(challenger), BOND, "still owed exactly one bond");
        assertEq(imd.balanceOf(address(reg)), BOND);
    }

    /// An owed bond survives the project's next life: relisting, a new challenge and a paid-out
    /// settlement leave the old debt untouched, and the registry still holds it.
    function test_owedBondSurvivesRelistingAndLaterPayouts() public {
        bytes32 id = _listAndChallenge();
        imd.setShape(ShapedIMD.Shape.False);
        assertTrue(_deliver(id, false));
        imd.setShape(ShapedIMD.Shape.True);
        assertEq(reg.bondOwed(challenger), BOND);

        vm.prank(applicant);
        id = reg.applyListing(project, "P", "https://x.example/p", 60, beneficiary);
        assertTrue(_deliver(id, true));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(applicant);
        id = reg.challengeForBeneficiary(project, "Second.", beneficiary);
        assertEq(imd.balanceOf(address(reg)), 2 * BOND, "owed bond plus the open one");
        uint256 before = imd.balanceOf(beneficiary);
        assertTrue(_deliver(id, true));
        assertEq(imd.balanceOf(beneficiary), before + BOND, "the new bond is paid at once");
        assertEq(imd.balanceOf(address(reg)), BOND, "the owed bond is still held");
        assertEq(reg.bondOwed(challenger), BOND);
        assertEq(reg.bondOwed(applicant), 0);
        assertEq(reg.bondOwed(beneficiary), 0);

        vm.prank(challenger);
        reg.claimBond(challenger);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    // ------------------------------------------------------------ claimBond

    /// A claim whose transfer fails changes nothing: the debt stays and can be claimed later.
    function test_claimRevertsWithoutLosingTheDebt() public {
        bytes32 id = _listAndChallenge();
        imd.setShape(ShapedIMD.Shape.RevertEmpty);
        assertTrue(_deliver(id, false));

        vm.prank(challenger);
        vm.expectRevert();
        reg.claimBond(challenger);
        assertEq(reg.bondOwed(challenger), BOND, "debt intact after a failed claim");

        // A token that returns false on the claim is refused by SafeERC20 too.
        imd.setShape(ShapedIMD.Shape.False);
        vm.prank(challenger);
        vm.expectRevert();
        reg.claimBond(other);
        assertEq(reg.bondOwed(challenger), BOND);

        imd.setShape(ShapedIMD.Shape.NoReturn);
        vm.prank(challenger);
        reg.claimBond(other);
        assertEq(imd.balanceOf(other), BOND);
        assertEq(reg.bondOwed(challenger), 0);
    }

    /// Only the creditor can claim: a third party, the destination wallet, or the beneficiary of
    /// the project cannot take a challenger's owed bond.
    function test_onlyTheCreditorClaims() public {
        bytes32 id = _listAndChallenge();
        imd.setShape(ShapedIMD.Shape.False);
        assertTrue(_deliver(id, false));
        imd.setShape(ShapedIMD.Shape.True);

        address[3] memory strangers = [other, beneficiary, applicant];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(ProjectRegistry.NothingOwed.selector);
            reg.claimBond(strangers[i]);
            vm.prank(strangers[i]);
            vm.expectRevert(ProjectRegistry.NothingOwed.selector);
            reg.claimBond(challenger);
        }
        assertEq(reg.bondOwed(challenger), BOND);
        assertEq(imd.balanceOf(address(reg)), BOND);
    }

    /// Claiming never touches an open challenge's bond: with one bond owed and another held for
    /// an open question, the claim pays exactly the owed amount.
    function test_claimLeavesOpenBondAlone() public {
        bytes32 id = _listAndChallenge();
        imd.setShape(ShapedIMD.Shape.False);
        assertTrue(_deliver(id, false));
        imd.setShape(ShapedIMD.Shape.True);

        vm.prank(applicant);
        id = reg.applyListing(project, "P", "https://x.example/p", 50, beneficiary);
        assertTrue(_deliver(id, true));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(applicant);
        id = reg.challengeForBeneficiary(project, "Open.", beneficiary);
        assertEq(imd.balanceOf(address(reg)), 2 * BOND);

        vm.prank(challenger);
        reg.claimBond(challenger);
        assertEq(imd.balanceOf(address(reg)), BOND, "the open bond stays");
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.Challenge));

        // And the open bond still settles to its rightful recipient.
        uint256 before = imd.balanceOf(applicant);
        assertTrue(_deliver(id, false));
        assertEq(imd.balanceOf(applicant), before + BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    /// Fuzz: however many times a refused bond is recorded for one wallet, the sum owed equals the
    /// bonds refused and one claim takes all of it.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_owedSumsAndClaimsOnce(uint8 rounds) public {
        rounds = uint8(bound(rounds, 1, 6));
        vm.prank(applicant);
        bytes32 id = reg.applyListing(project, "P", "https://x.example/p", 50, beneficiary);
        assertTrue(_deliver(id, true));
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < rounds; ++i) {
            vm.prank(challenger);
            id = reg.challengeForBeneficiary(project, "Review.", beneficiary);
            imd.setShape(i % 2 == 0 ? ShapedIMD.Shape.False : ShapedIMD.Shape.RevertLong);
            // Alternate failure, expiry and a defended answer: all refuse-and-owe paths.
            if (i % 3 == 0) {
                assertTrue(intake.fail(id, 2, "disagreed", CALLBACK_GAS));
            } else if (i % 3 == 1) {
                vm.warp(block.timestamp + 1 days + 1);
                reg.expire(project);
            } else {
                assertTrue(_deliver(id, true));
            }
            imd.setShape(ShapedIMD.Shape.True);
        }
        uint256 toChallenger = reg.bondOwed(challenger);
        uint256 toBeneficiary = reg.bondOwed(beneficiary);
        assertEq(toChallenger + toBeneficiary, uint256(rounds) * BOND, "every refused bond is owed");
        assertEq(imd.balanceOf(address(reg)), uint256(rounds) * BOND);
        if (toChallenger > 0) {
            vm.prank(challenger);
            reg.claimBond(other);
        }
        if (toBeneficiary > 0) {
            vm.prank(beneficiary);
            reg.claimBond(other);
        }
        assertEq(imd.balanceOf(other), uint256(rounds) * BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(reg.bondOwed(challenger) + reg.bondOwed(beneficiary), 0);
    }
}
