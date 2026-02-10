// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";

/**
 * @title RewardsFacet
 * @notice Manages check-in rewards for dining at partner venues
 * @dev This is how users earn 2BTL tokens!
 *      
 *      REWARD SYSTEM:
 *      - Base reward: 100 2BTL per check-in
 *      - Group multiplier: +50% for 4+ people
 *      - Venue multiplier: Set by venue (happy hour = 2x)
 *      - First-time bonus: +100% for first visit
 *      
 *      ANTI-GAMING MEASURES:
 *      - Max check-ins per day per user
 *      - Unique check-in hash (prevents replay)
 *      - Oracle signature required (prevents fake check-ins)
 */
contract RewardsFacet {
    
    // ============ Events ============
    event CheckInReward(
        address indexed user,
        address indexed venue,
        uint256 baseReward,
        uint256 multiplier,
        uint256 totalReward
    );
    event VenueAdded(address indexed venue, uint256 multiplier);
    event VenueUpdated(address indexed venue, uint256 multiplier, bool isActive);
    event ReferralReward(address indexed referrer, address indexed referee, uint256 reward);

    // ============ Check-In Functions ============

    /**
     * @notice Record a check-in and distribute rewards
     * @param user The user checking in
     * @param venue The venue address
     * @param groupSize Number of people in the group
     * @param checkInHash Unique hash to prevent replay
     * @dev Only callable by ORACLE (backend server)
     */
    function recordCheckIn(
        address user,
        address venue,
        uint256 groupSize,
        bytes32 checkInHash
    ) external returns (uint256 rewardAmount) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceIsOracle();
        LibAppStorage.enforceNotPaused();
        require(!s.rewardsPaused, "Rewards: Rewards are paused");
        require(user != address(0), "Rewards: Invalid user");
        require(venue != address(0), "Rewards: Invalid venue");
        
        // Venue must be active
        require(s.venues[venue].isActive, "Rewards: Venue not active");
        
        // Prevent replay attacks
        require(!s.usedCheckInHashes[checkInHash], "Rewards: Check-in already processed");
        s.usedCheckInHashes[checkInHash] = true;
        
        // Anti-gaming: Max check-ins per day
        uint256 today = block.timestamp / LibAppStorage.SECONDS_PER_DAY;
        require(
            s.dailyCheckIns[user][today] < s.maxCheckInsPerDay,
            "Rewards: Max check-ins per day reached"
        );
        s.dailyCheckIns[user][today]++;
        
        // Prevent same-block check-ins (flash loan protection)
        require(s.lastCheckInBlock[user] != block.number, "Rewards: Already checked in this block");
        s.lastCheckInBlock[user] = block.number;
        
        // Calculate reward
        rewardAmount = _calculateReward(user, venue, groupSize);
        
        // Update user stats
        LibAppStorage.RewardInfo storage rewardInfo = s.rewardInfo[user];
        rewardInfo.totalEarned += rewardAmount;
        rewardInfo.lastCheckIn = block.timestamp;
        rewardInfo.checkInCount++;
        
        // Update venue stats
        s.venues[venue].totalCheckIns++;
        s.venues[venue].rewardsDistributed += rewardAmount;
        
        // Update global stats
        s.totalCheckIns++;
        s.totalRewardsDistributed += rewardAmount;
        
        // Mint 2BTL rewards
        s.btlBalances[user] += rewardAmount;
        s.btlTotalSupply += rewardAmount;
        
        emit CheckInReward(
            user,
            venue,
            s.baseCheckInReward,
            s.venues[venue].multiplier,
            rewardAmount
        );
    }

    /**
     * @notice Claim referral reward when a friend makes their first check-in
     */
    function claimReferralReward(address referrer, address referee) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceIsOracle();
        LibAppStorage.enforceNotPaused();
        require(!s.rewardsPaused, "Rewards: Rewards are paused");
        
        // Referee must have checked in at least once
        require(s.rewardInfo[referee].checkInCount > 0, "Rewards: Referee has not checked in");
        
        uint256 referralReward = s.baseCheckInReward / 2; // 50 2BTL
        
        // Update referrer stats
        s.rewardInfo[referrer].referralCount++;
        s.rewardInfo[referrer].totalEarned += referralReward;
        
        // Mint reward
        s.btlBalances[referrer] += referralReward;
        s.btlTotalSupply += referralReward;
        
        emit ReferralReward(referrer, referee, referralReward);
    }

    // ============ View Functions ============

    /**
     * @notice Get reward info for a user
     */
    function getRewardInfo(address user) external view returns (
        uint256 totalEarned,
        uint256 lastCheckIn,
        uint256 checkInCount,
        uint256 referralCount
    ) {
        LibAppStorage.RewardInfo storage info = LibAppStorage.appStorage().rewardInfo[user];
        return (
            info.totalEarned,
            info.lastCheckIn,
            info.checkInCount,
            info.referralCount
        );
    }

    /**
     * @notice Estimate reward for a check-in
     */
    function estimateReward(
        address user,
        address venue,
        uint256 groupSize
    ) external view returns (uint256) {
        return _calculateReward(user, venue, groupSize);
    }

    /**
     * @notice Get venue information
     */
    function getVenueInfo(address venue) external view returns (
        bool isActive,
        uint256 multiplier,
        uint256 totalCheckIns,
        uint256 rewardsDistributed
    ) {
        LibAppStorage.VenueInfo storage info = LibAppStorage.appStorage().venues[venue];
        return (
            info.isActive,
            info.multiplier,
            info.totalCheckIns,
            info.rewardsDistributed
        );
    }

    /**
     * @notice Get all active venues
     */
    function getActiveVenues() external view returns (address[] memory venues) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        // Count active venues
        uint256 activeCount = 0;
        for (uint256 i = 0; i < s.venueList.length; i++) {
            if (s.venues[s.venueList[i]].isActive) {
                activeCount++;
            }
        }
        
        // Build array
        venues = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < s.venueList.length; i++) {
            if (s.venues[s.venueList[i]].isActive) {
                venues[index] = s.venueList[i];
                index++;
            }
        }
    }

    /**
     * @notice Get user's check-ins today
     */
    function getCheckInsToday(address user) external view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 today = block.timestamp / LibAppStorage.SECONDS_PER_DAY;
        return s.dailyCheckIns[user][today];
    }

    /**
     * @notice Get global stats
     */
    function getGlobalStats() external view returns (
        uint256 totalCheckIns,
        uint256 totalRewardsDistributed,
        uint256 totalProofMinted,
        uint256 totalProofRedeemed
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        return (
            s.totalCheckIns,
            s.totalRewardsDistributed,
            s.totalProofMinted,
            s.totalProofRedeemed
        );
    }

    // ============ Admin Functions ============

    /**
     * @notice Add a new venue
     */
    function addVenue(address venue, uint256 multiplier) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(
            s.roles[LibAppStorage.VENUE_MANAGER_ROLE][msg.sender] || 
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "Rewards: Not authorized"
        );
        require(venue != address(0), "Rewards: Invalid venue address");
        require(multiplier >= 50 && multiplier <= 500, "Rewards: Multiplier must be 0.5x to 5x");
        
        s.venues[venue] = LibAppStorage.VenueInfo({
            isActive: true,
            multiplier: multiplier,
            totalCheckIns: 0,
            rewardsDistributed: 0
        });
        
        s.venueList.push(venue);
        
        emit VenueAdded(venue, multiplier);
    }

    /**
     * @notice Update venue settings
     */
    function updateVenue(address venue, uint256 multiplier, bool isActive) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(
            s.roles[LibAppStorage.VENUE_MANAGER_ROLE][msg.sender] || 
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "Rewards: Not authorized"
        );
        require(multiplier >= 50 && multiplier <= 500, "Rewards: Multiplier must be 0.5x to 5x");
        
        s.venues[venue].multiplier = multiplier;
        s.venues[venue].isActive = isActive;
        
        emit VenueUpdated(venue, multiplier, isActive);
    }

    /**
     * @notice Set base check-in reward
     */
    function setBaseCheckInReward(uint256 baseReward) external {
        LibAppStorage.enforceIsAdmin();
        require(baseReward > 0 && baseReward <= 1000 * 1e18, "Rewards: Invalid base reward");
        
        LibAppStorage.appStorage().baseCheckInReward = baseReward;
    }

    /**
     * @notice Set max check-ins per day
     */
    function setMaxCheckInsPerDay(uint256 maxCheckIns) external {
        LibAppStorage.enforceIsAdmin();
        require(maxCheckIns >= 1 && maxCheckIns <= 10, "Rewards: Must be 1-10");
        
        LibAppStorage.appStorage().maxCheckInsPerDay = maxCheckIns;
    }

    /**
     * @notice Set group multiplier
     */
    function setGroupMultiplier(uint256 multiplier) external {
        LibAppStorage.enforceIsAdmin();
        require(multiplier >= 100 && multiplier <= 300, "Rewards: Multiplier 1x-3x");
        
        LibAppStorage.appStorage().groupMultiplier = multiplier;
    }

    /**
     * @notice Pause/unpause rewards
     */
    function setRewardsPaused(bool paused) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.appStorage().rewardsPaused = paused;
    }

    // ============ Internal Functions ============

    function _calculateReward(
        address user,
        address venue,
        uint256 groupSize
    ) internal view returns (uint256 reward) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        // Start with base reward
        reward = s.baseCheckInReward;
        
        // Apply venue multiplier (100 = 1x)
        reward = (reward * s.venues[venue].multiplier) / 100;
        
        // Apply group multiplier (50% bonus for 4+ people)
        if (groupSize >= 4) {
            reward = (reward * s.groupMultiplier) / 100;
        }
        
        // First-time bonus (100% bonus for first check-in)
        if (s.rewardInfo[user].checkInCount == 0) {
            reward = reward * 2;
        }
    }
}
