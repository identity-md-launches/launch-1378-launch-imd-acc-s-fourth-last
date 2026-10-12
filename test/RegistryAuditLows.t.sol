// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {RegistryBase} from "./ProjectRegistry.t.sol";

/// @dev The two low findings of the Sepolia test run 4 import audit, reproduced as the audit
/// describes them (see ADAPTATION.md). Both are the one-question-per-project rule at work and are
/// retained design limits (docs/design.md, "Known limits"; history section 22): the registry is
/// not changed for them. These tests pin what the limit costs and what it cannot do, so a later
/// change that widens either shows up here.
contract RegistryAuditLowsTest is RegistryBase {
    address internal attacker = makeAddr("attacker");
    address internal owner = makeAddr("owner");

    /// @dev Finding 77a0dce2: the beneficiary front-runs each outside challenge with its own,
    /// the outsider reverts AskOpen without paying, and a defended bond comes back to the
    /// beneficiary, so each cycle costs it exactly the oracle fee. The cooldown does not restart,
    /// so the outsider can file the moment the self-challenge settles, and a challenge the
    /// beneficiary files is still judged by the panel: a signed no delists it like any other.
    function test_selfChallengeCycleCostsOnlyTheFeeAndNeverRenewsImmunity() public {
        _listed();
        _fund(beneficiary);
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        vm.warp(openAt);
        for (uint256 i; i < 3; ++i) {
            uint256 before = imd.balanceOf(beneficiary);
            vm.prank(beneficiary);
            bytes32 id = reg.challengeForBeneficiary(project, "Fine.", beneficiary);
            vm.prank(challenger);
            vm.expectRevert(ProjectRegistry.AskOpen.selector);
            reg.challengeForBeneficiary(project, "It credits outside trades.", beneficiary);
            assertTrue(_answer(id, true));
            assertTrue(reg.isListed(project));
            assertEq(before - imd.balanceOf(beneficiary), 0.5e18, "a self-challenge costs the fee");
            assertEq(reg.projectOf(project).challengeOpenAt, openAt, "no new cooldown");
            // Not front-run this time: the outsider's challenge is filed at once, and a defended
            // one pays its bond to the beneficiary like any other.
            before = imd.balanceOf(beneficiary);
            vm.prank(challenger);
            bytes32 outside =
                reg.challengeForBeneficiary(project, "Outside challenge.", beneficiary);
            assertEq(reg.projectOf(project).asker, challenger);
            assertTrue(_answer(outside, true));
            assertEq(imd.balanceOf(beneficiary) - before, BOND);
        }
        assertEq(reg.bondOwed(beneficiary), 0);

        // A self-challenge the panel answers no delists the project and returns the bond.
        vm.prank(beneficiary);
        bytes32 own = reg.challengeForBeneficiary(project, "Fine again.", beneficiary);
        uint256 before = imd.balanceOf(beneficiary);
        assertTrue(_answer(own, false));
        assertFalse(reg.isListed(project));
        assertEq(imd.balanceOf(beneficiary) - before, BOND);
    }

    /// @dev Finding cfc4bf3a: a stranger's application with terms the panel will refuse holds the
    /// slot until it is answered; the project's own application reverts AskOpen and pays nothing.
    /// Each round costs the stranger the oracle fee and a panel; it never lists the stranger, and
    /// the slot is free the moment the signed no lands, in the same block.
    function test_doomedApplicationHoldsTheSlotOnlyUntilAnsweredAndNeverLists() public {
        _fund(attacker);
        _fund(owner);
        uint256 start = imd.balanceOf(attacker);
        uint256 ownerStart = imd.balanceOf(owner);
        for (uint256 i; i < 3; ++i) {
            vm.prank(attacker);
            bytes32 id = reg.applyListing(project, "x", "https://a.example/x", 25, attacker);
            vm.prank(owner);
            vm.expectRevert(ProjectRegistry.AskOpen.selector);
            reg.applyListing(project, "PLEA", "https://github.com/khaed1/plea", 50, owner);
            assertTrue(_answer(id, false));
            assertFalse(reg.isListed(project));
            assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
        }
        assertEq(start - imd.balanceOf(attacker), 3 * 0.5e18, "three fees spent");
        assertEq(imd.balanceOf(owner), ownerStart, "a reverted application costs nothing");

        // The round the stranger does not win, the owner's application is filed and listed.
        vm.prank(owner);
        bytes32 own = reg.applyListing(project, "PLEA", "https://github.com/khaed1/plea", 50, owner);
        vm.prank(attacker);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.applyListing(project, "x", "https://a.example/x", 25, attacker);
        assertTrue(_answer(own, true));
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOf(project).beneficiary, owner);
        // A listed project cannot be applied for again, so the slot can no longer be squatted.
        vm.prank(attacker);
        vm.expectRevert(ProjectRegistry.AlreadyListed.selector);
        reg.applyListing(project, "x", "https://a.example/x", 25, attacker);
    }
}
