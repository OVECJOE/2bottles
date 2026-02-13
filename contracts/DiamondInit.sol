// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./libraries/LibAppStorage.sol";
import "./libraries/LibDiamond.sol";
import "./libraries/LibVotes.sol";
import "./interfaces/IDiamondLoupe.sol";
import "./interfaces/IDiamondCut.sol";
import "./interfaces/IERC173.sol";

/**
 * @title DiamondInit
 * @notice One-time initialization of the Diamond's AppStorage
 * @dev Called via delegatecall during Diamond deployment to populate all
 *      initial state: token parameters, staking config, governance params,
 *      role assignments, and ERC-165 interface registrations.
 *
 *      An initialization guard ensures this can only execute once.
 *      For production deployments, set `initialTreasuryUSDC` to 0 and
 *      deposit real USDC through the TreasuryFacet after deployment.
 */
contract DiamondInit {

    struct InitArgs {
        uint256 initialBTLSupply;      // Initial 2BTL supply (e.g., 1 billion)
        address initialTokenHolder;     // Who receives initial supply
        uint256 initialTreasuryUSDC;   // 0 for production; non-zero only for testing
        address usdcAddress;            // USDC token address
        address daiAddress;             // DAI token address
        address admin;                  // Admin address
        address oracle;                 // Oracle address (backend)
        address venueManager;           // Venue manager address
        address treasuryManager;        // Treasury manager address
    }

    function init(InitArgs memory args) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();

        // Initialization guard — ensures this function cannot be called again
        require(!s.initialized, "DiamondInit: Already initialized");
        s.initialized = true;

        // ============ Initialize 2BTL Token ============
        s.btlName = "2bottles";
        s.btlSymbol = "2BTL";
        s.btlDecimals = 18;
        s.btlTotalSupply = args.initialBTLSupply;
        s.btlBalances[args.initialTokenHolder] = args.initialBTLSupply;
        s.btlTransferFee = 50; // 0.5% = 50 basis points

        // Write initial voting checkpoint for token holder
        LibVotes.transferVotingUnits(address(0), args.initialTokenHolder, args.initialBTLSupply);

        // ============ Initialize PROOF Token ============
        s.proofName = "Proof";
        s.proofSymbol = "PROOF";
        s.proofDecimals = 6;
        s.proofTotalSupply = 0; // Starts at zero, minted via staking

        // ============ Initialize Staking ============
        s.totalStaked = 0;
        s.stakingAPY = 1000; // 10% APY = 1000 basis points
        s.unstakeCooldown = 7 days;
        s.bondingCurveSlope = 500; // 5% conversion rate initially
        s.lastBondingCurveUpdate = block.timestamp;

        // ============ Initialize Rewards ============
        s.baseCheckInReward = 100 * 1e18; // 100 2BTL
        s.groupMultiplier = 150; // 1.5x for groups
        s.maxCheckInsPerDay = 3; // Anti-gaming

        // ============ Initialize Treasury ============
        s.treasuryUSDC = args.initialTreasuryUSDC;
        s.treasuryDAI = 0;
        s.minCollateralRatio = 12500; // 125%
        s.targetCollateralRatio = 15000; // 150%
        s.usdcAddress = args.usdcAddress;
        s.daiAddress = args.daiAddress;

        // ============ Initialize Governance ============
        s.proposalCount = 0;
        s.votingDelay = 7200; // ~1 day (assuming 12 sec blocks)
        s.votingPeriod = 21600; // ~3 days
        s.proposalThreshold = 1000 * 1e18; // Need 1000 2BTL to propose
        s.quorumVotes = 100000 * 1e18; // Need 100k 2BTL votes for quorum

        // ============ Initialize Access Control ============
        s.roles[LibAppStorage.ADMIN_ROLE][args.admin] = true;
        s.roles[LibAppStorage.ORACLE_ROLE][args.oracle] = true;
        s.roles[LibAppStorage.VENUE_MANAGER_ROLE][args.venueManager] = true;
        s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][args.treasuryManager] = true;

        // ============ Initialize Emergency State ============
        s.paused = false;
        s.stakingPaused = false;
        s.rewardsPaused = false;

        // ============ Initialize Stats ============
        s.totalCheckIns = 0;
        s.totalRewardsDistributed = 0;
        s.totalProofMinted = 0;
        s.totalProofRedeemed = 0;

        // ============ Set up ERC-165 interfaces ============
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;
    }
}
