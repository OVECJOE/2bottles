// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title LibAppStorage
 * @notice Shared storage layout for all 2bottles Diamond facets
 * @dev Implements the AppStorage pattern (EIP-2535 recommended) where all
 *      application state lives in a single struct at a deterministic storage
 *      slot, avoiding collisions with DiamondStorage.
 *
 *      STORAGE CONVENTIONS:
 *      - Treasury balances are stored in each token's native decimals (USDC=6, DAI=18)
 *      - Use `normalizedTreasuryTotal()` for cross-asset comparisons (normalizes to 6 decimals)
 *      - Role mutations emit indexed events for off-chain indexing
 *      - The `initialized` flag ensures the Diamond can only be initialized once
 */
library LibAppStorage {
    // ============ Storage Position ============
    bytes32 constant APP_STORAGE_POSITION = keccak256("2bottles.app.storage");

    // ============ Constants ============
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant SECONDS_PER_DAY = 86400;
    uint256 constant BLOCKS_PER_DAY = 7200;
    uint256 constant DECIMAL_NORMALIZATION = 1e12; // DAI(18) -> USDC(6) precision

    // ============ Role Constants ============
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 constant VENUE_MANAGER_ROLE = keccak256("VENUE_MANAGER_ROLE");
    bytes32 constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");

    // ============ Events ============
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    // ============ Structs ============

    struct StakeInfo {
        uint256 amount;
        uint256 stakedAt;
        uint256 proofMinted;
        uint256 lastRewardUpdate;
        uint256 accumulatedRewards; // Total APY rewards claimed
    }

    struct RewardInfo {
        uint256 totalEarned;
        uint256 lastCheckIn;
        uint256 checkInCount;
        uint256 referralCount;
    }

    struct VenueInfo {
        bool isActive;
        uint256 multiplier;
        uint256 totalCheckIns;
        uint256 rewardsDistributed;
    }

    struct Proposal {
        address proposer;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 startBlock;
        uint256 endBlock;
        bool executed;
        bool canceled;
        uint256 snapshotBlock;   // Block at which vote weights are snapshotted
        address[] targets;        // Execution: target contract addresses
        uint256[] values;         // Execution: ETH values per call
        bytes[] calldatas;        // Execution: calldata per call
    }

    struct Receipt {
        bool hasVoted;
        bool support;
        uint256 votes;
    }

    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    struct AppStorage {
        // ============ 2BTL Token State ============
        string btlName;
        string btlSymbol;
        uint8 btlDecimals;
        uint256 btlTotalSupply;
        mapping(address => uint256) btlBalances;
        mapping(address => mapping(address => uint256)) btlAllowances;
        uint256 btlTransferFee;

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
        uint256 stakingAPY;
        uint256 unstakeCooldown;
        mapping(address => uint256) unstakeRequestTime;
        mapping(address => uint256) unstakeRequestAmount; // Locked unstake amount per user

        // ============ Rewards State ============
        mapping(address => RewardInfo) rewardInfo;
        mapping(bytes32 => bool) usedCheckInHashes;
        uint256 baseCheckInReward;
        uint256 groupMultiplier;
        uint256 maxCheckInsPerDay;
        mapping(address => VenueInfo) venues;
        address[] venueList;
        mapping(address => mapping(address => bool)) referralClaimed; // referrer => referee => claimed

        // ============ Treasury State ============
        uint256 treasuryUSDC;  // Stored in USDC native decimals (6)
        uint256 treasuryDAI;   // Stored in DAI native decimals (18)
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

        // ============ Initialization Guard ============
        bool initialized;

        // ============ External Integrations ============
        address dexRouter;     // DEX router for treasury buybacks
        address btlWrapper;    // ERC20 wrapper contract for BTL
        address proofWrapper;  // ERC20 wrapper contract for PROOF
    }

    // ============ Storage Access ============

    function appStorage() internal pure returns (AppStorage storage s) {
        bytes32 position = APP_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    // ============ Access Control ============

    function enforceIsAdmin() internal view {
        require(appStorage().roles[ADMIN_ROLE][msg.sender], "LibAppStorage: Must be admin");
    }

    function enforceIsOracle() internal view {
        require(appStorage().roles[ORACLE_ROLE][msg.sender], "LibAppStorage: Must be oracle");
    }

    function enforceNotPaused() internal view {
        require(!appStorage().paused, "LibAppStorage: Contract is paused");
    }

    function hasRole(bytes32 role, address account) internal view returns (bool) {
        return appStorage().roles[role][account];
    }

    function grantRole(bytes32 role, address account) internal {
        appStorage().roles[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) internal {
        appStorage().roles[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }

    // ============ Treasury Helpers ============

    /**
     * @notice Get total treasury value normalized to USDC decimals (6)
     * @dev DAI (18 decimals) is divided by 1e12 to match USDC (6 decimals)
     */
    function normalizedTreasuryTotal() internal view returns (uint256) {
        AppStorage storage s = appStorage();
        uint256 normalizedDAI = s.treasuryDAI / DECIMAL_NORMALIZATION;
        return s.treasuryUSDC + normalizedDAI;
    }
}
