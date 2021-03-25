pragma solidity 0.6.12;

import "./interface/IVault.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";

contract CommunityTaxVault is IVault, ReentrancyGuard {

    address public governor;
    address public lbnbAddr;
    address public sbfAddr;
    address public pancakeRouterAddr;

    event Deposit(address from, uint256 amount);
    event Withdraw(address recipient, uint256 amount);
    event GovernorshipTransferred(address oldGovernor, address newGovernor);

    constructor(address payable _govAddr, address _lbnbAddr, address _sbfAddr, address _pancakeRouterAddr) public {
        governor = _govAddr;
        lbnbAddr = _lbnbAddr;
        sbfAddr = _sbfAddr;
        pancakeRouterAddr = _pancakeRouterAddr;
    }

    receive () external payable {
        emit Deposit(msg.sender, msg.value);
    }

    modifier onlyGov() {
        require(msg.sender == governor, "only governance is allowed");
        _;
    }

    function transferGovernorship(address newGovernor) external {
        require(msg.sender == governor, "only governor is allowed");
        require(newGovernor != address(0), "new governor is zero address");
        governor = newGovernor;
        emit GovernorshipTransferred(governor, newGovernor);
    }

    function claimBNB(uint256 amount, address payable recipient) nonReentrant onlyGov override external returns(uint256) {
        if (address(this).balance < amount) {
            amount = address(this).balance;
        }
        recipient.transfer(amount);
        emit Withdraw(recipient, amount);
        return amount;
    }

    function buyAndBurnSBF() nonReentrant onlyGov external returns(bool) {
        return true;
    }
}