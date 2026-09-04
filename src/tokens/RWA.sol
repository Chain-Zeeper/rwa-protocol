import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IComplianceHub} from "../token policy/IComplianceHub.sol";
contract RWA is ERC20 {

    IComplianceHub public complianceHub;
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(complianceHub.canTransfer(address(this), from, to, amount), "transfer not compliant");
        super._update(from, to, amount);
    }

}