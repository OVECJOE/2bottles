// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title LibAppStorage
 * @notice Defines the shared storage structure for all 2bottles facets
 * @dev Uses the "AppStorage" pattern where all app data lives in one struct
 *      This struct is stored at a specific storage slot to avoid collisions
 *      
 *      WHY THIS PATTERN?
 *      - All facets can access the same data
 *      - No storage collisions between facets
 *      - Easy to see all state in one place
 *      - More gas efficient than multiple storage reads
 */
library LibAppStorage {
    // ============ Storage Position ============
    bytes32 constant APP_STORAGE_POSITION = keccak256("2bottles.app.storage");

    // ============ Constants ============
    uint256 constant BASIS_POINTS = 10000; // For percentage calculations (100% = 10000)
    uint256 constant SECONDS_PER_DAY = 86400;
    uint256 constant BLOCKS_PER_DAY = 7200; // Assuming ~12 sec blocks

    // ============ Role Constants ============
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 constant VENUE_MANAGER_ROLE = keccak256("VENUE_MANAGER_ROLE");
    bytes32 constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");

    // ============ Structs ============

    /**
     * @dev Information about a user's stake
     */
    struct StakeInfo {
        uint256 amount;
        uint256 stakedAt;
        uint256 proofMinted;
        uint256 lastRewardUpdate;
    }

    /**
     * @dev Information about a user's rewards
     */
    struct RewardInfo {
        uint256 totalEarned;
        uint256 lastCheckIn;
        uint256 checkInCount;
        uint256 referralCount;
    }

    /**
     * @dev Information about a venue
     */
    struct VenueInfo {
        bool isActive;
        uint256 multiplier;
        uint256 totalCheckIns;
        uint256 rewardsDistributed;
    }

    /**
     * @dev Information about a governance proposal
     */
    struct Proposal {
        address proposer;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 startBlock;
        uint256 endBlock;
        bool executed;
        bool canceled;
    }

    /**
     * @dev Tracks voting on a proposal
     */
    struct Receipt {
        bool hasVoted;
        bool support;
        uint256 votes;
    }

    /**
     * @dev Checkpoint for vote delegation
     */
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /**
     * @dev The main application storage struct
     */
    struct AppStorage {
        // ============ 2BTL Token State ============
        string btlName;
        string btlSymbol;
        uint8 btlDecimals;
        uint256 btlTotalSupply;
        mapping(address => uint256) btlBalances;
        mapping(address => mapping(address => uint256)) btlAllowances;
        uint256 btlTransferFee; // Basis points (50 = 0.5%)

        // ============ PROOF Token State ============
        string proofName;
        string proofSymbol;
        uint8 proofDecimals;
        uint256 proofTotalSupply;
        mapping(address => uint256) proofBalances;
        mapping(address => mapping(address => uint256)) proofAllowances;

        // ============ Staking State ============
        mapping(address => StakeInfo) stakes;
        uint256 totalStaked;
        uint256 stakingAPY; // Basis points (1000 = 10%)
        uint256 unstakeCooldown;
        mapping(address => uint256) unstakeRequestTime;

        // ============ Rewards State ============
        mapping(address => RewardInfo) rewardInfo;
        mapping(bytes32 => bool) usedCheckInHashes;
        uint256 baseCheckInReward;
        uint256 groupMultiplier;
        uint256 maxCheckInsPerDay;
        mapping(address => VenueInfo) venues;
        address[] venueList;

        // ============ Treasury State ============
        uint256 treasuryUSDC;
        uint256 treasuryDAI;
        uint256 minCollateralRatio;
        uint256 targetCollateralRatio;
        address usdcAddress;
        address daiAddress;

        // ============ Governance State ============
        mapping(uint256 => Proposal) proposals;
        uint256 proposalCount;
        mapping(uint256 => mapping(address => Receipt)) receipts;
        uint256 votingDelay;
        uint256 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumVotes;
        mapping(address => address) delegates;
        mapping(address => uint256) numCheckpoints;
        mapping(address => mapping(uint256 => Checkpoint)) checkpoints;

        // ============ Access Control ============
        mapping(bytes32 => mapping(address => bool)) roles;

        // ============ Emergency State ============
        bool paused;
        bool stakingPaused;
        bool rewardsPaused;

        // ============ Bonding Curve State ============
        uint256 bondingCurveSlope;
        uint256 lastBondingCurveUpdate;

        // ============ Anti-Gaming ============
        mapping(address => mapping(uint256 => uint256)) dailyCheckIns;
        mapping(address => uint256) lastCheckInBlock;

        // ============ Stats & Analytics ============
        uint256 totalCheckIns;
        uint256 totalRewardsDistributed;
        uint256 totalProofMinted;
        uint256 totalProofRedeemed;
    }

    // ============ Storage Access ============

    /**
     * @notice Get the app storage struct
     */
    function appStorage() internal pure returns (AppStorage storage s) {
        bytes32 position = APP_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    // ============ Role Modifiers ============

    function enforceIsAdmin() internal view {
        AppStorage storage s = appStorage();
        require(s.roles[ADMIN_ROLE][msg.sender], "LibAppStorage: Must be admin");
    }

    function enforceIsOracle() internal view {
        AppStorage storage s = appStorage();
        require(s.roles[ORACLE_ROLE][msg.sender], "LibAppStorage: Must be oracle");
    }

    function enforceNotPaused() internal view {
        require(!appStorage().paused, "LibAppStorage: Contract is paused");
    }

    function hasRole(bytes32 role, address account) internal view returns (bool) {
        return appStorage().roles[role][account];
    }

    function grantRole(bytes32 role, address account) internal {
        appStorage().roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) internal {
        appStorage().roles[role][account] = false;
    }
}
