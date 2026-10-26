import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IComplianceHub} from "../token policy/IComplianceHub.sol";
contract RWA is ERC20 {

    // Fixed at deploy: every mint, transfer and burn is checked against it.
    IComplianceHub public immutable complianceHub;

    constructor(string memory name, string memory symbol, IComplianceHub _complianceHub) ERC20(name, symbol) {
        require(address(_complianceHub) != address(0), "zero compliance hub");
        complianceHub = _complianceHub;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(complianceHub.canTransfer(address(this), from, to, amount), "transfer not compliant");
        super._update(from, to, amount);
    }

}
