// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";
import "../libraries/LibReentrancyGuard.sol";
import "../libraries/LibVotes.sol";

/**
 * @title StakingFacet
 * @notice Stake 2BTL to mint PROOF tokens and earn APY rewards
 * @dev Implements a bonding-curve-based staking system where users lock 2BTL
 *      and receive PROOF proportional to the current curve slope and treasury
 *      health. Key mechanics:
 *
 *      - Collateral ratio is enforced before every PROOF mint
 *      - Unstake requests lock a specific amount for a cooldown period
 *      - APY rewards accrue continuously and are claimable in 2BTL
 *      - All balance changes update LibVotes checkpoints for governance
 */
contract StakingFacet {

    // ============ Events ============
    event Staked(address indexed user, uint256 btlAmount, uint256 proofMinted);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 btlAmount);
    event BondingCurveUpdated(uint256 newSlope);
    event StakingRewardClaimed(address indexed user, uint256 reward);

    // ============ Modifiers ============
    modifier nonReentrant() {
        LibReentrancyGuard.nonReentrantBefore();
        _;
        LibReentrancyGuard.nonReentrantAfter();
    }

    // ============ Staking Functions ============

    /**
     * @notice Stake 2BTL to mint PROOF tokens via the bonding curve
     * @param btlAmount Amount of 2BTL to stake
     * @return proofMinted Amount of PROOF minted to the caller
     */
    function stake(uint256 btlAmount) external nonReentrant returns (uint256 proofMinted) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(!s.stakingPaused, "Staking: Staking is paused");
        require(btlAmount > 0, "Staking: Cannot stake zero");
        require(s.btlBalances[msg.sender] >= btlAmount, "Staking: Insufficient 2BTL balance");

        // Calculate PROOF to mint via bonding curve
        proofMinted = calculateProofMint(btlAmount);
        require(proofMinted > 0, "Staking: PROOF amount too small");

        // Enforce collateralization before minting new PROOF
        uint256 newProofSupply = s.proofTotalSupply + proofMinted;
        uint256 requiredCollateral = (newProofSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        uint256 totalCollateral = LibAppStorage.normalizedTreasuryTotal();
        require(totalCollateral >= requiredCollateral, "Staking: Would break collateral ratio");

        // Claim any pending APY rewards before updating stake
        _claimPendingRewards(msg.sender);

        // Transfer BTL from user to staking pool
        unchecked {
            s.btlBalances[msg.sender] -= btlAmount;
        }
        s.btlBalances[address(this)] += btlAmount;

        // Update voting checkpoints (BTL moved from user to contract)
        LibVotes.transferVotingUnits(msg.sender, address(this), btlAmount);

        // Update stake info
        LibAppStorage.StakeInfo storage stakeInfo = s.stakes[msg.sender];
        stakeInfo.amount += btlAmount;
        stakeInfo.stakedAt = block.timestamp;
        stakeInfo.proofMinted += proofMinted;
        stakeInfo.lastRewardUpdate = block.timestamp;

        s.totalStaked += btlAmount;

        // Mint PROOF to user (collateral already checked above)
        s.proofBalances[msg.sender] += proofMinted;
        s.proofTotalSupply += proofMinted;
        s.totalProofMinted += proofMinted;

        emit Staked(msg.sender, btlAmount, proofMinted);
    }

    /**
     * @notice Request to unstake — locks a specific 2BTL amount for the cooldown period
     * @param btlAmount Amount of 2BTL to unstake
     */
    function requestUnstake(uint256 btlAmount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(btlAmount > 0, "Staking: Cannot unstake zero");

        LibAppStorage.StakeInfo storage stakeInfo = s.stakes[msg.sender];
        require(stakeInfo.amount >= btlAmount, "Staking: Insufficient staked amount");

        // Lock the requested amount — only this amount can be withdrawn after cooldown
        s.unstakeRequestTime[msg.sender] = block.timestamp;
        s.unstakeRequestAmount[msg.sender] = btlAmount;

        uint256 unlockTime = block.timestamp + s.unstakeCooldown;
        emit UnstakeRequested(msg.sender, btlAmount, unlockTime);
    }

    /**
     * @notice Execute a pending unstake after the cooldown period has elapsed
     * @dev Withdraws the exact amount locked during `requestUnstake`. No amount
     *      parameter is accepted to prevent manipulation between request and execution.
     */
    function executeUnstake() external nonReentrant {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();

        uint256 requestTime = s.unstakeRequestTime[msg.sender];
        uint256 btlAmount = s.unstakeRequestAmount[msg.sender];
        require(requestTime > 0, "Staking: No unstake request found");
        require(btlAmount > 0, "Staking: No amount locked for unstake");
        require(
            block.timestamp >= requestTime + s.unstakeCooldown,
            "Staking: Cooldown not passed"
        );

        LibAppStorage.StakeInfo storage stakeInfo = s.stakes[msg.sender];
        require(stakeInfo.amount >= btlAmount, "Staking: Insufficient staked amount");

        // Claim pending APY rewards
        _claimPendingRewards(msg.sender);

        // Update stake info
        unchecked {
            stakeInfo.amount -= btlAmount;
            s.totalStaked -= btlAmount;
            s.btlBalances[address(this)] -= btlAmount;
        }
        s.btlBalances[msg.sender] += btlAmount;

        // Update voting checkpoints (BTL returns from contract to user)
        LibVotes.transferVotingUnits(address(this), msg.sender, btlAmount);

        // Clear unstake request
        s.unstakeRequestTime[msg.sender] = 0;
        s.unstakeRequestAmount[msg.sender] = 0;

        emit Unstaked(msg.sender, btlAmount);
    }

    /**
     * @notice Claim accumulated staking APY rewards in 2BTL
     */
    function claimStakingRewards() external nonReentrant {
        LibAppStorage.enforceNotPaused();
        uint256 pending = _calculatePendingRewards(msg.sender);
        require(pending > 0, "Staking: No rewards to claim");
        _claimPendingRewards(msg.sender);
    }

    // ============ View Functions ============

    function getStakeInfo(address user) external view returns (
        uint256 amount,
        uint256 stakedAt,
        uint256 proofMinted,
        uint256 pendingRewards
    ) {
        LibAppStorage.StakeInfo storage info = LibAppStorage.appStorage().stakes[user];
        return (info.amount, info.stakedAt, info.proofMinted, _calculatePendingRewards(user));
    }

    function getTotalStaked() external view returns (uint256) {
        return LibAppStorage.appStorage().totalStaked;
    }

    function canUnstake(address user) external view returns (
        bool canUnstakeNow,
        uint256 timeRemaining,
        uint256 requestedAmount
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 requestTime = s.unstakeRequestTime[user];
        requestedAmount = s.unstakeRequestAmount[user];

        if (requestTime == 0 || requestedAmount == 0) {
            return (false, 0, 0);
        }

        uint256 unlockTime = requestTime + s.unstakeCooldown;
        if (block.timestamp >= unlockTime) {
            return (true, 0, requestedAmount);
        } else {
            return (false, unlockTime - block.timestamp, requestedAmount);
        }
    }

    function calculateProofMint(uint256 btlAmount) public view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();

        // Base: BTL * slope / BASIS_POINTS
        uint256 baseProof = (btlAmount * s.bondingCurveSlope) / LibAppStorage.BASIS_POINTS;

        // Adjust based on collateral health
        uint256 currentRatio = _getCurrentCollateralRatio();
        uint256 targetRatio = s.targetCollateralRatio > 0 ? s.targetCollateralRatio : LibAppStorage.BASIS_POINTS;
        uint256 adjustment = (currentRatio * LibAppStorage.BASIS_POINTS) / targetRatio;

        uint256 adjustedProof = (baseProof * adjustment) / LibAppStorage.BASIS_POINTS;

        // Convert from 18 decimals (2BTL) to 6 decimals (PROOF)
        return adjustedProof / 1e12;
    }

    function getStakingAPY() external view returns (uint256) {
        return LibAppStorage.appStorage().stakingAPY;
    }

    function getUnstakeCooldown() external view returns (uint256) {
        return LibAppStorage.appStorage().unstakeCooldown;
    }

    // ============ Admin Functions ============

    function updateBondingCurve(uint256 newSlope) external {
        LibAppStorage.enforceIsAdmin();
        require(newSlope > 0 && newSlope <= 10000, "Staking: Invalid slope");

        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        s.bondingCurveSlope = newSlope;
        s.lastBondingCurveUpdate = block.timestamp;

        emit BondingCurveUpdated(newSlope);
    }

    function setUnstakeCooldown(uint256 cooldownSeconds) external {
        LibAppStorage.enforceIsAdmin();
        require(
            cooldownSeconds >= 1 days && cooldownSeconds <= 30 days,
            "Staking: Cooldown must be 1-30 days"
        );
        LibAppStorage.appStorage().unstakeCooldown = cooldownSeconds;
    }

    function setStakingAPY(uint256 apyBasisPoints) external {
        LibAppStorage.enforceIsAdmin();
        require(apyBasisPoints <= 5000, "Staking: APY cannot exceed 50%");
        LibAppStorage.appStorage().stakingAPY = apyBasisPoints;
    }

    function setStakingPaused(bool _paused) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.appStorage().stakingPaused = _paused;
    }

    // ============ Internal Functions ============

    function _getCurrentCollateralRatio() internal view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        if (s.proofTotalSupply == 0) {
            return s.targetCollateralRatio > 0 ? s.targetCollateralRatio : LibAppStorage.BASIS_POINTS;
        }
        uint256 totalCollateral = LibAppStorage.normalizedTreasuryTotal();
        return (totalCollateral * LibAppStorage.BASIS_POINTS) / s.proofTotalSupply;
    }

    /**
     * @notice Calculate pending APY rewards for a staker
     * @dev rewards = stakedAmount * APY * timeElapsed / (365 days * BASIS_POINTS)
     */
    function _calculatePendingRewards(address user) internal view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.StakeInfo storage stakeInfo = s.stakes[user];
        if (stakeInfo.amount == 0 || stakeInfo.lastRewardUpdate == 0) return 0;

        uint256 timeElapsed = block.timestamp - stakeInfo.lastRewardUpdate;
        return (stakeInfo.amount * s.stakingAPY * timeElapsed) / (365 days * LibAppStorage.BASIS_POINTS);
    }

    function _claimPendingRewards(address user) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.StakeInfo storage stakeInfo = s.stakes[user];

        uint256 pending = _calculatePendingRewards(user);
        if (pending > 0) {
            // Mint 2BTL rewards
            s.btlBalances[user] += pending;
            s.btlTotalSupply += pending;
            stakeInfo.accumulatedRewards += pending;

            // Update voting checkpoints for newly minted BTL
            LibVotes.transferVotingUnits(address(0), user, pending);

            emit StakingRewardClaimed(user, pending);
        }
        stakeInfo.lastRewardUpdate = block.timestamp;
    }
}
