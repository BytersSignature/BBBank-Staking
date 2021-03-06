pragma solidity 0.6.12;

import "./interface/ITokenHub.sol";
import "./interface/IVault.sol";
import "./interface/IMintBurnToken.sol";

import "openzeppelin-solidity/contracts/GSN/Context.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-solidity/contracts/proxy/Initializable.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";

contract StakeBankImpl is Context, Initializable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public constant ZERO_ADDR = 0x0000000000000000000000000000000000000000;
    address public constant TOKENHUB_ADDR = 0x0000000000000000000000000000000000001004;

    uint8 constant public  BreathePeriod = 0;
    uint8 constant public  NormalPeriod = 1;

    uint256 public constant minimumStake = 1 * 1e18; // 1:BNB
    uint256 public constant exchangeRatePrecision = 1e9;

    address public LBNB;
    address public SBF;
    address public bcStakingTSS;
    address public stakingRewardMaintainer;
    address payable public communityTaxVault;
    address payable public stakingRewardVault;
    address payable public unstakeVault;

    address public admin;
    address public pendingAdmin;

    bool private _paused;

    struct Unstake {
        address payable staker;
        uint256 amount;
        uint256 timestamp;
    }

    uint256 public lbnbMarketCapacityCountByBNB;
    uint256 public lbnbToBNBExchangeRate;
    mapping(uint256 => Unstake) public unstakesMap;
    mapping(address => uint256[]) public accountUnstakeSeqsMap;
    uint256 public headerIdx;
    uint256 public tailIdx;

    mapping(address => uint256) public stakingReward;

    uint256 public priceToAccelerateUnstake;
    uint256 public stakeFeeMolecular;
    uint256 public stakeFeeDenominator;
    uint256 public unstakeFeeMolecular;
    uint256 public unstakeFeeDenominator;

    event NewAdmin(address indexed newAdmin);
    event NewPendingAdmin(address indexed newPendingAdmin);
    event LogStake(address indexed staker, uint256 lbnbAmount, uint256 bnbAmount);
    event LogUnstake(address indexed staker, uint256 lbnbAmount, uint256 bnbAmount, uint256 index);
    event ClaimedUnstake(address indexed staker, uint256 amount, uint256 index);
    event LogUpdateLBNBToBNBExchangeRate(uint256 LBNBTotalSupply, uint256 LBNBMarketCapacityCountByBNB, uint256 LBNBToBNBExchangeRate);
    event Paused(address account);
    event Unpaused(address account);
    event ReceiveDeposit(address from, uint256 amount);
    event AcceleratedUnstakedBNB(address AcceleratedStaker, uint256 AcceleratedUnstakeIdx);
    event Deposit(address from, uint256 amount);

    constructor() public {}

    /* solium-disable-next-line */
    receive () external payable {
        emit Deposit(msg.sender, msg.value);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin is allowed");
        _;
    }

    modifier onlyRewardMaintainer() {
        require(msg.sender == stakingRewardMaintainer, "only admin is allowed");
        _;
    }

    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    modifier mustInMode(uint8 expectedMode) {
        require(getMode() == expectedMode, "Wrong mode");
        _;
    }

    modifier notContract() {
        require(!isContract(msg.sender), "contract is not allowed");
        require(msg.sender == tx.origin, "no proxy contract is allowed");
        _;
    }

    function isContract(address addr) internal view returns (bool) {
        uint size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }

    function getMode() public view returns (uint8) {
        uint256 UTCTime = block.timestamp%86400;
        if (UTCTime<=600 || UTCTime>85200) {
            return BreathePeriod;
        } else {
            return NormalPeriod;
        }
    }

    function initialize(
        address _admin,
        address _LBNB,
        address _SBF,
        address _bcStakingTSS,
        address _stakingRewardMaintainer,
        address payable _communityTaxVault,
        address payable _stakingRewardVault,
        address payable _unstakeVault,
        uint256 _priceToAccelerateUnstake
    ) external initializer{
        admin = _admin;

        lbnbToBNBExchangeRate = exchangeRatePrecision;
        LBNB = _LBNB;
        SBF = _SBF;

        bcStakingTSS = _bcStakingTSS;
        stakingRewardMaintainer = _stakingRewardMaintainer;

        communityTaxVault = _communityTaxVault;
        stakingRewardVault = _stakingRewardVault;
        unstakeVault = _unstakeVault;

        priceToAccelerateUnstake = _priceToAccelerateUnstake;
        stakeFeeMolecular = 1;
        stakeFeeDenominator = 1000;
        unstakeFeeMolecular = 1;
        unstakeFeeDenominator = 1000;
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    function pause() external onlyAdmin whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    function unpause() external onlyAdmin whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "StakingBank::acceptAdmin: Call must come from pendingAdmin.");
        admin = msg.sender;
        pendingAdmin = address(0);

        emit NewAdmin(admin);
    }

    function setPendingAdmin(address pendingAdmin_) external {
        require(msg.sender == admin, "StakingBank::setPendingAdmin: Call must come from admin.");
        pendingAdmin = pendingAdmin_;

        emit NewPendingAdmin(pendingAdmin);
    }

    function setBCStakingTSS(address newBCStakingTSS) onlyAdmin external {
        bcStakingTSS = newBCStakingTSS;
    }

    function setCommunityTaxVault(address payable newCommunityTaxVault) onlyAdmin external {
        communityTaxVault = newCommunityTaxVault;
    }

    function setStakingRewardVault(address payable newStakingRewardVault) onlyAdmin external {
        stakingRewardVault = newStakingRewardVault;
    }

    function setUnstakeVault(address payable newUnstakeVault) onlyAdmin external {
        unstakeVault = newUnstakeVault;
    }

    function setPriceToAccelerateUnstake(uint256 newPriceToAccelerateUnstake) onlyAdmin external {
        priceToAccelerateUnstake = newPriceToAccelerateUnstake;
    }

    function setStakeFeeMolecular(uint256 newStakeFeeMolecular) onlyAdmin external {
        require(stakeFeeDenominator>newStakeFeeMolecular , "invalid stakeFeeMolecular");
        stakeFeeMolecular = newStakeFeeMolecular;
    }

    function setStakeFeeDenominator(uint256 newStakeFeeDenominator) onlyAdmin external {
        require(newStakeFeeDenominator>stakeFeeMolecular&&newStakeFeeDenominator!=0 , "invalid stakeFeeDenominator");
        stakeFeeDenominator = newStakeFeeDenominator;
    }

    function setUnstakeFeeMolecular(uint256 newUnstakeFeeMolecular) onlyAdmin external {
        require(unstakeFeeDenominator>newUnstakeFeeMolecular , "invalid unstakeFeeMolecular");
        unstakeFeeMolecular = newUnstakeFeeMolecular;
    }

    function setUnstakeFeeDenominator(uint256 newUnstakeFeeDenominator) onlyAdmin external {
        require(newUnstakeFeeDenominator>unstakeFeeMolecular&&newUnstakeFeeDenominator!=0 , "invalid unstakeFeeDenominator");
        unstakeFeeDenominator = newUnstakeFeeDenominator;
    }

    function stake(uint256 amount) notContract nonReentrant mustInMode(NormalPeriod) whenNotPaused external payable returns (bool) {

        uint256 miniRelayFee = ITokenHub(TOKENHUB_ADDR).getMiniRelayFee();

        require(msg.value == amount.add(miniRelayFee), "msg.value must equal to amount + miniRelayFee");
        require(amount%1e10==0 && amount>=minimumStake, "stake amount must be N * 1e10 and be greater than minimumStake");

        uint256 stakeFee = amount.mul(stakeFeeMolecular).div(stakeFeeDenominator);
        communityTaxVault.transfer(stakeFee);
        uint256 stakeAmount = amount.sub(stakeFee);
        lbnbMarketCapacityCountByBNB = lbnbMarketCapacityCountByBNB.add(stakeAmount);
        uint256 lbnbAmount = stakeAmount.mul(exchangeRatePrecision).div(lbnbToBNBExchangeRate);

        uint256 stakeAmountDust = stakeAmount.mod(1e10);
        if (stakeAmountDust != 0) {
            unstakeVault.transfer(stakeAmountDust);
            stakeAmount = stakeAmount.sub(stakeAmountDust);
        }

        ITokenHub(TOKENHUB_ADDR).transferOut{value:miniRelayFee.add(stakeAmount)}(ZERO_ADDR, bcStakingTSS, stakeAmount, uint64(block.timestamp + 3600));

        IMintBurnToken(LBNB).mintTo(msg.sender, lbnbAmount);
        emit LogStake(msg.sender, lbnbAmount, stakeAmount);

        return true;
    }

    function unstake(uint256 amount) notContract nonReentrant mustInMode(NormalPeriod) whenNotPaused external returns (bool) {
        uint256 unstakeFee = amount.mul(unstakeFeeMolecular).div(unstakeFeeDenominator);
        IERC20(LBNB).safeTransferFrom(msg.sender, communityTaxVault, unstakeFee);

        uint256 unstakeAmount = amount.sub(unstakeFee);
        IERC20(LBNB).safeTransferFrom(msg.sender, address(this), unstakeAmount);
        IMintBurnToken(LBNB).burn(unstakeAmount);

        uint256 bnbAmount = unstakeAmount.mul(lbnbToBNBExchangeRate).div(exchangeRatePrecision);
        bnbAmount = bnbAmount.sub(bnbAmount.mod(1e10));
        lbnbMarketCapacityCountByBNB = lbnbMarketCapacityCountByBNB.sub(bnbAmount);
        unstakesMap[tailIdx] = Unstake({
            staker: msg.sender,
            amount: bnbAmount,
            timestamp: block.timestamp
        });
        uint256[] storage unstakes = accountUnstakeSeqsMap[msg.sender];
        unstakes.push(tailIdx);

        emit LogUnstake(msg.sender, unstakeAmount, bnbAmount, tailIdx);
        tailIdx++;
        return true;
    }

    function estimateSBFCostForAccelerate(uint256 unstakeIndex, uint256 steps) external view returns (uint256) {
        if (steps == 0) return 0;
        if (unstakeIndex<steps) return 0;
        if ((unstakeIndex.sub(steps))<headerIdx || unstakeIndex>=tailIdx) return 0;

        Unstake memory unstake = unstakesMap[unstakeIndex];
        uint256 sbfBurnAmount = unstake.amount.mul(steps).mul(priceToAccelerateUnstake);
        for (uint256 idx = unstakeIndex.sub(1) ; idx >= unstakeIndex.sub(steps); idx--) {
            Unstake memory priorUnstake = unstakesMap[idx];
            sbfBurnAmount = sbfBurnAmount.add(priorUnstake.amount.mul(priceToAccelerateUnstake));
        }
        return sbfBurnAmount;
    }

    function accelerateUnstakedMature(uint256 unstakeIndex, uint256 steps, uint256 sbfMaxCost) nonReentrant whenNotPaused external returns (bool) {
        require(steps > 0, "accelerate steps must be greater than zero");
        require(unstakeIndex.sub(steps)>=headerIdx && unstakeIndex<tailIdx, "unstakeIndex is out of valid accelerate range");

        Unstake memory unstake = unstakesMap[unstakeIndex];
        require(unstake.staker==msg.sender, "only staker can accelerate itself");

        uint256 sbfBurnAmount = unstake.amount.mul(steps).mul(priceToAccelerateUnstake);
        for (uint256 idx = unstakeIndex.sub(1) ; idx >= unstakeIndex.sub(steps); idx--) {
            Unstake memory priorUnstake = unstakesMap[idx];
            unstakesMap[idx+1] = priorUnstake;
            sbfBurnAmount = sbfBurnAmount.add(priorUnstake.amount.mul(priceToAccelerateUnstake));
            uint256[] storage priorUnstakeSeqs = accountUnstakeSeqsMap[priorUnstake.staker];
            bool found = false;
            for(uint256 i=0; i < priorUnstakeSeqs.length; i++) {
                if (priorUnstakeSeqs[i]==idx) {
                    priorUnstakeSeqs[i]=idx+1;
                    found = true;
                    break;
                }
            }
            require(found, "failed to find matched unstake sequence");
        }

        uint256[] storage unstakeSeqs = accountUnstakeSeqsMap[msg.sender];
        unstakesMap[unstakeIndex.sub(steps)] = unstake;
        bool found = false;
        for(uint256 idx=0; idx < unstakeSeqs.length; idx++) {
            if (unstakeSeqs[idx]==unstakeIndex) {
                unstakeSeqs[idx] = unstakeIndex.sub(steps);
                found = true;
                break;
            }
        }
        require(found, "failed to find matched unstake sequence");

        require(sbfBurnAmount<=sbfMaxCost, "cost too much SBF");
        IERC20(SBF).safeTransferFrom(msg.sender, address(this), sbfBurnAmount);
        IMintBurnToken(SBF).burn(sbfBurnAmount);

        emit AcceleratedUnstakedBNB(msg.sender, unstakeIndex);

        return true;
    }

    function getUnstakeSeqsLength(address addr) external view returns (uint256) {
        return accountUnstakeSeqsMap[addr].length;
    }

    function getUnstakeSequence(address addr, uint256 idx) external view returns (uint256) {
        return accountUnstakeSeqsMap[addr][idx];
    }

    function isUnstakeClaimable(uint256 unstakeSeq) external view returns (bool) {
        if (unstakeSeq < headerIdx || unstakeSeq >= tailIdx) {
            return false;
        }
        uint256 totalUnstakeAmount = 0;
        for(uint256 idx=headerIdx; idx <= unstakeSeq; idx++) {
            Unstake memory unstake = unstakesMap[idx];
            totalUnstakeAmount=totalUnstakeAmount.add(unstake.amount);
        }
        return unstakeVault.balance >= totalUnstakeAmount;
    }

    function batchClaimPendingUnstake(uint256 batchSize) nonReentrant whenNotPaused external {
        for(uint256 idx=0; idx < batchSize && headerIdx < tailIdx; idx++) {
            Unstake memory unstake = unstakesMap[headerIdx];
            uint256 unstakeBNBAmount = unstake.amount;
            if (unstakeVault.balance < unstakeBNBAmount) {
                return;
            }
            delete unstakesMap[headerIdx];
            uint256 actualAmount = IVault(unstakeVault).claimBNB(unstakeBNBAmount, unstake.staker);
            require(actualAmount==unstakeBNBAmount, "amount mismatch");
            emit ClaimedUnstake(unstake.staker, unstake.amount, headerIdx);

            uint256[] storage unstakeSeqs = accountUnstakeSeqsMap[unstake.staker];
            uint256 lastSeq = unstakeSeqs[unstakeSeqs.length-1];
            if (lastSeq != headerIdx) {
                bool found = false;
                for(uint256 index=0; index < unstakeSeqs.length; index++) {
                    if (unstakeSeqs[index]==headerIdx) {
                        unstakeSeqs[index] = lastSeq;
                        found = true;
                        break;
                    }
                }
                require(found, "failed to find matched unstake sequence");
            }
            unstakeSeqs.pop();

            headerIdx++;
        }
    }

    function rebaseLBNBToBNB() whenNotPaused external returns(bool) {
        uint256 rewardVaultBalance = stakingRewardVault.balance;
        require(rewardVaultBalance>0, "stakingRewardVault has no BNB");
        uint256 actualAmount = IVault(stakingRewardVault).claimBNB(rewardVaultBalance, unstakeVault);
        require(rewardVaultBalance==actualAmount, "reward amount mismatch");

        uint256 lbnbTotalSupply = IERC20(LBNB).totalSupply();
        lbnbMarketCapacityCountByBNB = lbnbMarketCapacityCountByBNB.add(rewardVaultBalance);
        if (lbnbTotalSupply == 0) {
            lbnbToBNBExchangeRate = exchangeRatePrecision;
        } else {
            lbnbToBNBExchangeRate = lbnbMarketCapacityCountByBNB.mul(exchangeRatePrecision).div(lbnbTotalSupply);
        }
        emit LogUpdateLBNBToBNBExchangeRate(lbnbTotalSupply, lbnbMarketCapacityCountByBNB, lbnbToBNBExchangeRate);
        return true;
    }

    function resendBNBToBCStakingTSS(uint256 amount) onlyRewardMaintainer whenNotPaused external payable returns(bool) {

        uint256 miniRelayFee = ITokenHub(TOKENHUB_ADDR).getMiniRelayFee();

        require(msg.value == miniRelayFee, "msg.value must equal to miniRelayFee");
        require(address(this).balance >= amount, "stakeBank BNB balance is not enough");
        require(amount%1e10==0, "amount must be N * 1e10");

        ITokenHub(TOKENHUB_ADDR).transferOut{value:miniRelayFee.add(amount)}(ZERO_ADDR, bcStakingTSS, amount, uint64(block.timestamp + 3600));

        return true;
    }
}
