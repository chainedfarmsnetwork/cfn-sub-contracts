// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./Token.sol";

// MasterChef is the master of Token. He can make Token and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once TOKEN is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp; // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.

        // We do some fancy math here. Basically, any point in time, the amount of TOKENs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. TOKENs to distribute per block.
        uint256 lastRewardBlock; // Last block number that TOKENs distribution occurs.
        uint256 accTokenPerShare; // Accumulated TOKENs per share, times 1e12. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        uint256 harvestInterval; // Harvest interval in seconds
    }

    // The TOKEN TOKEN!
    Token public token;
    // Dev address.
    address public devaddr;
    // TOKEN tokens created per block.
    uint256 public tokenPerBlock;
    // Bonus muliplier for early token makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;
    // Dev Fee turned on/off
    bool public devFees;
    // Dev Fee Percentage
    uint256 public devFeesPercent;
    // Emission rate at token start
    uint256 public baseEmissionRate;
    // Maximum emission rate per block possible
    uint256 public maxEmissionRate;
    // CFN Address
    address public cfnAddress;
    // Previous Subfarm Token Address
    address public prevSfnAddress;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when TOKEN mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    constructor(
        Token _token,
        address _devaddr,
        address _feeAddress,
        uint256 _tokenPerBlock,
        uint256 _startBlock,
        bool _devFees,
        uint256 _devFeesPercent,
        uint256 _baseEmissionRate,
        uint256 _maxEmissionRate,
        address _cfnAddress,
        address _prevSfnAddress
    ) public {
        require(_devFeesPercent <= 500, "Incorrect dev fees: too high value");
        require(_baseEmissionRate < _maxEmissionRate, "Incorrect base emission rate, higher than max emission rate");
        require(_tokenPerBlock < _maxEmissionRate, "Incorrect token per block, higher than max emission rate");
        token = _token;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        tokenPerBlock = _tokenPerBlock;
        startBlock = _startBlock;
        devFees = _devFees;
        devFeesPercent = _devFeesPercent;
        baseEmissionRate = _baseEmissionRate;
        maxEmissionRate = _maxEmissionRate;
        cfnAddress = _cfnAddress;
        prevSfnAddress = _prevSfnAddress;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // View function to see if user can harvest
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        uint16 _depositFeeBP,
        uint256 _harvestInterval,
        bool _withUpdate
    ) public onlyOwner {
        // Capped at 6%, project constraint
        require(_depositFeeBP <= 600, "add: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accTokenPerShare: 0,
                depositFeeBP: _depositFeeBP,
                harvestInterval: _harvestInterval
            })
        );
    }

    // Update the given pool's TOKEN allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint256 _harvestInterval,
        bool _withUpdate
    ) public onlyOwner {
        // Capped at 6%, project constraint
        require(_depositFeeBP <= 600, "set: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending TOKENs on frontend.
    function pendingToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accTokenPerShare = accTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Recalculate and update the emission rate
    function updateEmissionRatePerBlock() public {
        // i.e: 1500 token supply running, 5000 max supply, base rate of 1 token/block
        // 1*(5000/1500)-1 = 2,33 token/block minted
        uint256 newEmissionRate =
            baseEmissionRate.mul(token.getMaximumSupply()).div(token.totalSupply()) - baseEmissionRate;

        // If new emission rate is under 0 or circulating supply is greater than
        // maximum supply's soft cap, stop minting to encourage transactions & burn
        if (newEmissionRate < 0 || token.totalSupply() > token.getMaximumSupply()) {
            tokenPerBlock = 0;
        }
        // Else if the new emission rate is lower than the max emission rate allowed...
        else if (newEmissionRate < maxEmissionRate) {
            tokenPerBlock = newEmissionRate;
        }
        // Else, emission rate = max emission rate allowed
        else {
            tokenPerBlock = maxEmissionRate;
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 tokenReward = multiplier.mul(tokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        // If devfees (instead of everytime like in base contract) is true,
        // also mint percentage of tokens to dev (more about this on related dev fees functions)
        // Note that in most other farms contracts you can find a 10% dev mint
        if (devFees) {
            token.mint(devaddr, tokenReward.mul(devFeesPercent).div(10000));
        }

        token.mint(address(this), tokenReward);

        updateEmissionRatePerBlock();

        pool.accTokenPerShare = pool.accTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for TOKEN allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // A bit tricky part, we need to store _amount in another variable to be able to use it later
        // Quick summarize: baseAmount is used for smart contract transfers while _amount will be used
        // for front-end synchronization purpose
        uint256 baseAmount = _amount;

        updatePool(_pid);

        // INSERT PAYORLOCKUP HERE ?
        payOrLockupPendingToken(_pid);
        // if (user.amount > 0) {
        //     uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        //     if (pending > 0) {
        //         safeTokenTransfer(msg.sender, pending);
        //     }
        // }

        if (_amount > 0) {
            // Because our own token have a specific burn system, we need to calculate and remove the burn amount
            // when its staked in single token pool, we need to be specific because only our token has the
            // getCurrentBurnPercent() method
            if (address(pool.lpToken) == cfnAddress || address(pool.lpToken) == prevSfnAddress) {
                if (pool.lpToken.getCurrentBurnPercent() > 0) {
                    uint256 burnAmount = _amount.mul(pool.lpToken.getCurrentBurnPercent()).div(10000);
                    _amount = _amount.sub(burnAmount);
                }
            }

            // Here we use the baseAmount, not _amount because they are different, baseAmount
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), baseAmount);
            // From our pool we will a
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee); // << using _amount (front-end purposes)
            } else {
                user.amount = user.amount.add(_amount); // << using _amount (front-end purposes)
            }
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        // Using baseAmount to emit transfert so we are synchronized with our token supply
        emit Deposit(msg.sender, _pid, baseAmount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        // INSERT PAYORLOCKUP HERE?
        payOrLockupPendingToken(_pid);
        // uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        // if (pending > 0) {
        //     safeTokenTransfer(msg.sender, pending);
        // }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }

        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Burn the pending tokens to ensure they are not stuck
        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeTokenTransfer(token.getDeadAddress(), pending);
        }

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;

        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending Tokens.
    function payOrLockupPendingToken(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                // send rewards
                safeTokenTransfer(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe token transfer function, just in case if rounding error causes pool to not have enough TOKENs.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 tokenBal = token.balanceOf(address(this));
        if (_amount > tokenBal) {
            token.transfer(_to, tokenBal);
        } else {
            token.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    // Allow to change ownership of the token for more flexibility in case we need to fix something
    // in masterchef, must be used very carefully
    function transferTokenOwnership(address _newAddress) public onlyOwner {
        require(_newAddress != address(0), "Ownable: new owner is the zero address");
        require(msg.sender == devaddr, "dev: wut?");
        token.transferOwnership(_newAddress);
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
    }

    // Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    // This should not be used:
    // Emission rate is auto calculated at each block from updatePool() that is using the public updateEmissionRate()

    // function updateEmissionRate(uint256 _tokenPerBlock) public onlyOwner {
    //     massUpdatePools();
    //     tokenPerBlock = _tokenPerBlock;
    // }

    // Set devFees
    function updateDevFees(bool _devFees) public onlyOwner {
        devFees = _devFees;
    }

    // Set devFeesPercent, should not be used but available in case of extra token needs (airdrops, contests...)
    // And most of all for further subfarms liquidity providing (please read project's doc before fuding :))
    // Capped at a maximum of 5%
    function updateDevFeesPercent(uint256 _devFeesPercent) public onlyOwner {
        require(_devFeesPercent <= 500, "updateDevFeesPercent: too high value");
        devFeesPercent = _devFeesPercent;
    }

    // Because the auto-burn system is kinda new and never saw it in action, this function will allow to
    // externally update the base emission rate in case the supply is getting burn way faster than predicted
    // MUST BE USED CAREFULLY, TWEAKING THIS NUMBER CAN RESULT IN SOME SERIOUS ECONOMICAL IMPACT
    function updateBaseEmissionRate(uint256 _baseEmissionRate) public onlyOwner {
        require(
            _baseEmissionRate <= maxEmissionRate,
            "updateBaseEmissionRate: too high value, must be under max emission rate"
        );
        baseEmissionRate = _baseEmissionRate;
    }

    // Because we can tweak manually base emission rate, we need to be able to tweak the max emission rate too :)
    function updateMaxEmissionRate(uint256 _maxEmissionRate) public onlyOwner {
        require(_maxEmissionRate >= baseEmissionRate, "updateMaxEmissionRate: too low value");
        maxEmissionRate = _maxEmissionRate;
    }
}
