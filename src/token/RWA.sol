// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IComplianceHub} from "../compliance/IComplianceHub.sol";
import {IERC7943Fungible} from "../interfaces/IERC7943.sol";

// ERC-7943 (uRWA) token. Eligibility and transfer rules come from the
// compliance hub. Who may freeze (_checkFreezer) and force transfers
// (_checkEnforcer) is left to the concrete token, as is issuance: this base
// has no mint or burn of its own. Hook names and signatures follow
// OpenZeppelin's ERC20uRWA.
abstract contract RWA is ERC20, ERC165, IERC7943Fungible {

    // Fixed at deploy: every mint, transfer and burn is checked against it.
    IComplianceHub public immutable complianceHub;

    // May exceed the balance, so tokens received later arrive frozen.
    mapping(address => uint256) private _frozenTokens;

    constructor(string memory name, string memory symbol, IComplianceHub _complianceHub) ERC20(name, symbol) {
        require(address(_complianceHub) != address(0), "zero compliance hub");
        complianceHub = _complianceHub;
    }

    // Revert unless msg.sender may freeze `amount` of `account`'s tokens /
    // force `amount` from `from` to `to`. Arguments allow finer rules (e.g.
    // per-agent limits); most implementations only check a role.
    function _checkFreezer(address account, uint256 amount) internal view virtual;
    function _checkEnforcer(address from, address to, uint256 amount) internal view virtual;

    // ------------------------------------------------------------------ views
    // ERC-7943 views must not revert, so a reverting hub (e.g. a rule whose
    // code changed) reads as "not allowed".

    function canSend(address account) public view returns (bool) {
        try complianceHub.canSend(address(this), account) returns (bool ok) { return ok; } catch { return false; }
    }

    function canReceive(address account) public view returns (bool) {
        try complianceHub.canReceive(address(this), account) returns (bool ok) { return ok; } catch { return false; }
    }

    // An amount above the whole balance isn't refused here: ERC-7943 leaves
    // plain balance failures to ERC-20.
    function canTransfer(address from, address to, uint256 amount) external view returns (bool) {
        if (amount <= balanceOf(from) && amount > _unfrozenBalance(from)) return false;
        if (!canSend(from) || !canReceive(to)) return false;
        try complianceHub.canTransfer(address(this), from, to, amount) returns (bool ok) { return ok; } catch { return false; }
    }

    function getFrozenTokens(address account) external view returns (uint256) {
        return _frozenTokens[account];
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC7943Fungible).interfaceId || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------ enforcement

    function setFrozenTokens(address account, uint256 amount) external returns (bool) {
        _checkFreezer(account, amount);
        _frozenTokens[account] = amount;
        emit Frozen(account, amount);
        return true;
    }

    // Moves tokens without the holder: court orders, lost keys, sanctions.
    // Bypasses the sender's eligibility, frozen balance and transfer rules, but
    // the recipient must still be able to receive.
    function forcedTransfer(address from, address to, uint256 amount) external returns (bool) {
        _checkEnforcer(from, to, amount);
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        if (!canReceive(to)) revert ERC7943CannotReceive(to);
        _releaseFrozen(from, amount);
        ERC20._update(from, to, amount);   // skips this contract's _update checks
        emit ForcedTransfer(from, to, amount);
        return true;
    }

    // Every ordinary mint, transfer and burn; forcedTransfer goes around it.
    // Burns count as permissioned: they skip the sender's eligibility and may
    // consume frozen tokens, so a holder who can't send can still be redeemed.
    // A derived contract exposing burn to holders must add those checks itself.
    function _update(address from, address to, uint256 amount) internal override {
        if (to == address(0)) {
            _releaseFrozen(from, amount);
        } else {
            if (from != address(0)) {
                if (_frozenTokens[from] != 0) {
                    uint256 unfrozen = _unfrozenBalance(from);
                    if (amount > unfrozen) revert ERC7943InsufficientUnfrozenBalance(from, amount, unfrozen);
                }
                if (!complianceHub.canSend(address(this), from)) revert ERC7943CannotSend(from);
            }
            if (!complianceHub.canReceive(address(this), to)) revert ERC7943CannotReceive(to);
        }
        if (!complianceHub.canTransfer(address(this), from, to, amount)) revert ERC7943CannotTransfer(from, to, amount);
        super._update(from, to, amount);
    }

    function _unfrozenBalance(address account) private view returns (uint256) {
        uint256 balance = balanceOf(account);
        uint256 frozen = _frozenTokens[account];
        return balance > frozen ? balance - frozen : 0;
    }

    // Before a permissioned move out of `from`: if it dips into frozen tokens,
    // unfreeze the shortfall and emit Frozen (ERC-7943 wants it before the
    // Transfer event). Any excess freeze on top of the balance is kept.
    function _releaseFrozen(address from, uint256 amount) private {
        uint256 unfrozen = _unfrozenBalance(from);
        if (amount <= unfrozen) return;
        uint256 frozen = _frozenTokens[from];
        uint256 shortfall = amount - unfrozen;
        // shortfall > frozen only when amount > balance; ERC20 reverts on that.
        uint256 newFrozen = shortfall < frozen ? frozen - shortfall : 0;
        _frozenTokens[from] = newFrozen;
        emit Frozen(from, newFrozen);
    }

}
