// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";
import "../libraries/LibReentrancyGuard.sol";
import "../libraries/LibVotes.sol";

/**
 * @title RewardsFacet
 * @notice Check-in rewards for dining at partner venues
 * @dev Oracle-gated reward distribution with anti-gaming protections:
 *
 *      - Per-day check-in limits and per-block uniqueness
 *      - Venue-specific reward multipliers
 *      - Group dining bonuses
 *      - Deduplicated referral rewards (one claim per referrer/referee pair)
 *      - Paginated venue listing to avoid gas limit issues at scale
 *      - All reward minting updates LibVotes checkpoints for governance
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

    // ============ Modifiers ============
    modifier nonReentrant() {
        LibReentrancyGuard.nonReentrantBefore();
        _;
        LibReentrancyGuard.nonReentrantAfter();
    }

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
    ) external nonReentrant returns (uint256 rewardAmount) {
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

        // Update voting checkpoints for newly minted BTL
        LibVotes.transferVotingUnits(address(0), user, rewardAmount);

        emit CheckInReward(
            user,
            venue,
            s.baseCheckInReward,
            s.venues[venue].multiplier,
            rewardAmount
        );
    }

    /**
     * @notice Claim referral reward for bringing a new user
     * @dev Only callable by ORACLE. Each referrer/referee pair can claim exactly once.
     * @param referrer The existing user who referred
     * @param referee The new user who was referred
     */
    function claimReferralReward(address referrer, address referee) external nonReentrant {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceIsOracle();
        LibAppStorage.enforceNotPaused();
        require(!s.rewardsPaused, "Rewards: Rewards are paused");
        require(referrer != address(0) && referee != address(0), "Rewards: Invalid addresses");
        require(referrer != referee, "Rewards: Cannot self-refer");

        // Each referrer/referee pair is tracked to prevent duplicate claims
        require(!s.referralClaimed[referrer][referee], "Rewards: Referral already claimed");
        s.referralClaimed[referrer][referee] = true;

        // Referee must have checked in at least once
        require(s.rewardInfo[referee].checkInCount > 0, "Rewards: Referee has not checked in");

        uint256 referralReward = s.baseCheckInReward / 2; // 50 2BTL

        // Update referrer stats
        s.rewardInfo[referrer].referralCount++;
        s.rewardInfo[referrer].totalEarned += referralReward;

        // Mint reward
        s.btlBalances[referrer] += referralReward;
        s.btlTotalSupply += referralReward;

        // Update voting checkpoints
        LibVotes.transferVotingUnits(address(0), referrer, referralReward);

        emit ReferralReward(referrer, referee, referralReward);
    }

    // ============ View Functions ============

    function getRewardInfo(address user) external view returns (
        uint256 totalEarned,
        uint256 lastCheckIn,
        uint256 checkInCount,
        uint256 referralCount
    ) {
        LibAppStorage.RewardInfo storage info = LibAppStorage.appStorage().rewardInfo[user];
        return (info.totalEarned, info.lastCheckIn, info.checkInCount, info.referralCount);
    }

    function estimateReward(
        address user,
        address venue,
        uint256 groupSize
    ) external view returns (uint256) {
        return _calculateReward(user, venue, groupSize);
    }

    function getVenueInfo(address venue) external view returns (
        bool isActive,
        uint256 multiplier,
        uint256 totalCheckIns,
        uint256 rewardsDistributed
    ) {
        LibAppStorage.VenueInfo storage info = LibAppStorage.appStorage().venues[venue];
        return (info.isActive, info.multiplier, info.totalCheckIns, info.rewardsDistributed);
    }

    /**
     * @notice Get active venues with pagination to avoid gas limits
     * @param offset Start index in venueList
     * @param limit Max venues to return
     */
    function getActiveVenues(uint256 offset, uint256 limit) external view returns (
        address[] memory venues,
        uint256 totalVenues
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        totalVenues = s.venueList.length;

        if (offset >= totalVenues || limit == 0) {
            return (new address[](0), totalVenues);
        }

        uint256 end = offset + limit;
        if (end > totalVenues) end = totalVenues;

        // Count active in range
        uint256 activeCount = 0;
        for (uint256 i = offset; i < end; i++) {
            if (s.venues[s.venueList[i]].isActive) activeCount++;
        }

        venues = new address[](activeCount);
        uint256 idx = 0;
        for (uint256 i = offset; i < end; i++) {
            if (s.venues[s.venueList[i]].isActive) {
                venues[idx++] = s.venueList[i];
            }
        }
    }

    function getCheckInsToday(address user) external view returns (uint256) {
        uint256 today = block.timestamp / LibAppStorage.SECONDS_PER_DAY;
        return LibAppStorage.appStorage().dailyCheckIns[user][today];
    }

    function getGlobalStats() external view returns (
        uint256 totalCheckIns,
        uint256 totalRewardsDistributed,
        uint256 totalProofMinted,
        uint256 totalProofRedeemed
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        return (s.totalCheckIns, s.totalRewardsDistributed, s.totalProofMinted, s.totalProofRedeemed);
    }

    function isReferralClaimed(address referrer, address referee) external view returns (bool) {
        return LibAppStorage.appStorage().referralClaimed[referrer][referee];
    }

    // ============ Admin Functions ============

    function addVenue(address venue, uint256 multiplier) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(
            s.roles[LibAppStorage.VENUE_MANAGER_ROLE][msg.sender] ||
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "Rewards: Not authorized"
        );
        require(venue != address(0), "Rewards: Invalid venue address");
        require(!s.venues[venue].isActive, "Rewards: Venue already exists");
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

    function setBaseCheckInReward(uint256 baseReward) external {
        LibAppStorage.enforceIsAdmin();
        require(baseReward > 0 && baseReward <= 1000 * 1e18, "Rewards: Invalid base reward");
        LibAppStorage.appStorage().baseCheckInReward = baseReward;
    }

    function setMaxCheckInsPerDay(uint256 maxCheckIns) external {
        LibAppStorage.enforceIsAdmin();
        require(maxCheckIns >= 1 && maxCheckIns <= 10, "Rewards: Must be 1-10");
        LibAppStorage.appStorage().maxCheckInsPerDay = maxCheckIns;
    }

    function setGroupMultiplier(uint256 multiplier) external {
        LibAppStorage.enforceIsAdmin();
        require(multiplier >= 100 && multiplier <= 300, "Rewards: Multiplier 1x-3x");
        LibAppStorage.appStorage().groupMultiplier = multiplier;
    }

    function setRewardsPaused(bool _paused) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.appStorage().rewardsPaused = _paused;
    }

    // ============ Internal Functions ============

    function _calculateReward(
        address user,
        address venue,
        uint256 groupSize
    ) internal view returns (uint256 reward) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();

        reward = s.baseCheckInReward;

        // Venue multiplier (100 = 1x)
        reward = (reward * s.venues[venue].multiplier) / 100;

        // Group multiplier (50% bonus for 4+ people)
        if (groupSize >= 4) {
            reward = (reward * s.groupMultiplier) / 100;
        }

        // First-time bonus (100% bonus for first check-in)
        if (s.rewardInfo[user].checkInCount == 0) {
            reward = reward * 2;
        }
    }
}
