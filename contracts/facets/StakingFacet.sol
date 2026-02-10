// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";

/**
 * @title StakingFacet
 * @notice Stake 2BTL to mint PROOF tokens via bonding curve
 * @dev This is the bridge between volatile 2BTL and stable PROOF
 *      
 *      HOW IT WORKS:
 *      1. User stakes 2BTL (locked for 7 days default)
 *      2. System mints PROOF based on bonding curve
 *      3. After cooldown, user can unstake and get 2BTL back
 *      4. PROOF remains in circulation (unless burned)
 *      
 *      SECURITY:
 *      - Cooldown prevents flash loan attacks
 *      - Collateralization ratio enforced
 *      - Pausable in emergency
 */
contract StakingFacet {
    
    // ============ Events ============
    event Staked(address indexed user, uint256 btlAmount, uint256 proofMinted);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 btlAmount);
    event BondingCurveUpdated(uint256 newSlope);

    // ============ Staking Functions ============

    /**
     * @notice Stake 2BTL to mint PROOF
     * @param btlAmount Amount of 2BTL to stake
     * @return proofMinted Amount of PROOF minted
     */
    function stake(uint256 btlAmount) external returns (uint256 proofMinted) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(!s.stakingPaused, "Staking: Staking is paused");
        require(btlAmount > 0, "Staking: Cannot stake zero");
        require(s.btlBalances[msg.sender] >= btlAmount, "Staking: Insufficient 2BTL balance");
        
        // Calculate PROOF to mint using bonding curve
        proofMinted = calculateProofMint(btlAmount);
        require(proofMinted > 0, "Staking: PROOF amount too small");
        
        // Transfer 2BTL from user to contract (staking pool)
        unchecked {
            s.btlBalances[msg.sender] -= btlAmount;
        }
        s.btlBalances[address(this)] += btlAmount;
        
        // Update stake info
        LibAppStorage.StakeInfo storage stakeInfo = s.stakes[msg.sender];
        stakeInfo.amount += btlAmount;
        stakeInfo.stakedAt = block.timestamp;
        stakeInfo.proofMinted += proofMinted;
        stakeInfo.lastRewardUpdate = block.timestamp;
        
        s.totalStaked += btlAmount;
        
        // Mint PROOF to user
        s.proofBalances[msg.sender] += proofMinted;
        s.proofTotalSupply += proofMinted;
        s.totalProofMinted += proofMinted;
        
        emit Staked(msg.sender, btlAmount, proofMinted);
    }

    /**
     * @notice Request to unstake 2BTL (starts cooldown)
     * @param btlAmount Amount of 2BTL to unstake
     */
    function requestUnstake(uint256 btlAmount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(btlAmount > 0, "Staking: Cannot unstake zero");
        
        LibAppStorage.StakeInfo storage stakeInfo = s.stakes[msg.sender];
        require(stakeInfo.amount >= btlAmount, "Staking: Insufficient staked amount");
        
        // Set unstake request time
        s.unstakeRequestTime[msg.sender] = block.timestamp;
        
        uint256 unlockTime = block.timestamp + s.unstakeCooldown;
        emit UnstakeRequested(msg.sender, btlAmount, unlockTime);
    }

    /**
     * @notice Execute unstake after cooldown period
     * @param btlAmount Amount of 2BTL to unstake
     */
    function executeUnstake(uint256 btlAmount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(btlAmount > 0, "Staking: Cannot unstake zero");
        
        // Check cooldown
        uint256 requestTime = s.unstakeRequestTime[msg.sender];
        require(requestTime > 0, "Staking: No unstake request found");
        require(block.timestamp >= requestTime + s.unstakeCooldown, "Staking: Cooldown not passed");
        
        LibAppStorage.StakeInfo storage stakeInfo = s.stakes[msg.sender];
        require(stakeInfo.amount >= btlAmount, "Staking: Insufficient staked amount");
        
        // Update stake info
        unchecked {
            stakeInfo.amount -= btlAmount;
            s.totalStaked -= btlAmount;
            s.btlBalances[address(this)] -= btlAmount;
        }
        s.btlBalances[msg.sender] += btlAmount;
        
        // Clear unstake request
        s.unstakeRequestTime[msg.sender] = 0;
        
        emit Unstaked(msg.sender, btlAmount);
    }

    // ============ View Functions ============

    /**
     * @notice Get staking info for a user
     */
    function getStakeInfo(address user) external view returns (
        uint256 amount,
        uint256 stakedAt,
        uint256 proofMinted
    ) {
        LibAppStorage.StakeInfo storage info = LibAppStorage.appStorage().stakes[user];
        return (info.amount, info.stakedAt, info.proofMinted);
    }

    /**
     * @notice Get total amount staked across all users
     */
    function getTotalStaked() external view returns (uint256) {
        return LibAppStorage.appStorage().totalStaked;
    }

    /**
     * @notice Check if user can unstake
     */
    function canUnstake(address user) external view returns (bool canUnstakeNow, uint256 timeRemaining) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 requestTime = s.unstakeRequestTime[user];
        
        if (requestTime == 0) {
            return (false, 0);
        }
        
        uint256 unlockTime = requestTime + s.unstakeCooldown;
        
        if (block.timestamp >= unlockTime) {
            return (true, 0);
        } else {
            return (false, unlockTime - block.timestamp);
        }
    }

    /**
     * @notice Calculate how much PROOF would be minted for staking
     * @param btlAmount Amount of 2BTL to stake
     * @return proofAmount Amount of PROOF that would be minted
     */
    function calculateProofMint(uint256 btlAmount) public view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        // Base calculation: BTL * slope
        uint256 baseProof = (btlAmount * s.bondingCurveSlope) / LibAppStorage.BASIS_POINTS;
        
        // Adjust based on collateralization ratio
        uint256 currentRatio = _getCurrentCollateralRatio();
        uint256 targetRatio = s.targetCollateralRatio > 0 ? s.targetCollateralRatio : LibAppStorage.BASIS_POINTS;
        uint256 adjustment = (currentRatio * LibAppStorage.BASIS_POINTS) / targetRatio;
        
        uint256 adjustedProof = (baseProof * adjustment) / LibAppStorage.BASIS_POINTS;
        
        // Convert from 18 decimals (2BTL) to 6 decimals (PROOF)
        return adjustedProof / 1e12;
    }

    /**
     * @notice Get current staking APY
     */
    function getStakingAPY() external view returns (uint256) {
        return LibAppStorage.appStorage().stakingAPY;
    }

    /**
     * @notice Get unstake cooldown period
     */
    function getUnstakeCooldown() external view returns (uint256) {
        return LibAppStorage.appStorage().unstakeCooldown;
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the bonding curve slope
     */
    function updateBondingCurve(uint256 newSlope) external {
        LibAppStorage.enforceIsAdmin();
        require(newSlope > 0 && newSlope <= 10000, "Staking: Invalid slope");
        
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        s.bondingCurveSlope = newSlope;
        s.lastBondingCurveUpdate = block.timestamp;
        
        emit BondingCurveUpdated(newSlope);
    }

    /**
     * @notice Set the unstake cooldown period
     */
    function setUnstakeCooldown(uint256 cooldownSeconds) external {
        LibAppStorage.enforceIsAdmin();
        require(cooldownSeconds >= 1 days && cooldownSeconds <= 30 days, "Staking: Invalid cooldown");
        
        LibAppStorage.appStorage().unstakeCooldown = cooldownSeconds;
    }

    /**
     * @notice Set staking APY
     */
    function setStakingAPY(uint256 apyBasisPoints) external {
        LibAppStorage.enforceIsAdmin();
        require(apyBasisPoints <= 5000, "Staking: APY too high"); // Max 50%
        
        LibAppStorage.appStorage().stakingAPY = apyBasisPoints;
    }

    /**
     * @notice Pause/unpause staking
     */
    function setStakingPaused(bool paused) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.appStorage().stakingPaused = paused;
    }

    // ============ Internal Functions ============

    function _getCurrentCollateralRatio() internal view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        if (s.proofTotalSupply == 0) {
            return s.targetCollateralRatio > 0 ? s.targetCollateralRatio : LibAppStorage.BASIS_POINTS;
        }
        
        uint256 totalCollateral = s.treasuryUSDC + s.treasuryDAI;
        return (totalCollateral * LibAppStorage.BASIS_POINTS) / s.proofTotalSupply;
    }
}
