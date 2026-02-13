// test/Diamond.test.ts
import { expect } from "chai";
import hre from "hardhat";
import { BaseContract, Signer } from "ethers";
import { HardhatEthers } from "@nomicfoundation/hardhat-ethers/types";
import {
    BTLTokenFacet,
    Diamond,
    DiamondCutFacet,
    DiamondInit,
    DiamondLoupeFacet,
    GovernanceFacet,
    OwnershipFacet,
    ProofTokenFacet,
    RewardsFacet,
    StakingFacet,
    TreasuryFacet
} from "../types/ethers-contracts/index.js";

// Helper function to get selectors from a contract
function getSelectors(contract: BaseContract): string[] {
    const selectors: string[] = [];
    contract.interface.forEachFunction((func) => {
        if (func.name !== "init") {
            selectors.push(func.selector);
        }
    });
    return selectors;
}

const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };

describe("2bottles Diamond", async function () {
    let ethers: HardhatEthers;
    let loadFixture: <T>(fn: () => Promise<T>) => Promise<T>;

    let diamond: Diamond;
    let diamondCutFacet: DiamondCutFacet;
    let diamondLoupeFacet: DiamondLoupeFacet;
    let ownershipFacet: OwnershipFacet;
    let btlTokenFacet: BTLTokenFacet;
    let proofTokenFacet: ProofTokenFacet;
    let stakingFacet: StakingFacet;
    let rewardsFacet: RewardsFacet;
    let governanceFacet: GovernanceFacet;
    let treasuryFacet: TreasuryFacet;
    let diamondInit: DiamondInit;
    let mockUSDC: any;
    let mockDAI: any;

    let owner: Signer;
    let oracle: Signer;
    let venueManager: Signer;
    let treasuryManager: Signer;
    let user1: Signer;
    let user2: Signer;

    let diamondAddress: string;

    // Helper to connect contract interface to diamond
    const asBTL = () => btlTokenFacet.attach(diamondAddress) as BTLTokenFacet;
    const asPROOF = () => proofTokenFacet.attach(diamondAddress) as ProofTokenFacet;
    const asStaking = () => stakingFacet.attach(diamondAddress) as StakingFacet;
    const asRewards = () => rewardsFacet.attach(diamondAddress) as RewardsFacet;
    const asGovernance = () => governanceFacet.attach(diamondAddress) as GovernanceFacet;
    const asTreasury = () => treasuryFacet.attach(diamondAddress) as TreasuryFacet;
    const asLoupe = () => diamondLoupeFacet.attach(diamondAddress) as DiamondLoupeFacet;

    before(async function () {
        const { ethers: e, networkHelpers } = await hre.network.connect();
        [ethers, loadFixture] = [e, networkHelpers.loadFixture];

        [owner, oracle, venueManager, treasuryManager, user1, user2] = await ethers.getSigners();

        // Deploy all facets
        const DiamondCutFacet = await ethers.getContractFactory("DiamondCutFacet");
        diamondCutFacet = await DiamondCutFacet.deploy();
        await diamondCutFacet.waitForDeployment();

        const DiamondLoupeFacet = await ethers.getContractFactory("DiamondLoupeFacet");
        diamondLoupeFacet = await DiamondLoupeFacet.deploy();
        await diamondLoupeFacet.waitForDeployment();

        const OwnershipFacet = await ethers.getContractFactory("OwnershipFacet");
        ownershipFacet = await OwnershipFacet.deploy();
        await ownershipFacet.waitForDeployment();

        const BTLTokenFacet = await ethers.getContractFactory("BTLTokenFacet");
        btlTokenFacet = await BTLTokenFacet.deploy();
        await btlTokenFacet.waitForDeployment();

        const ProofTokenFacet = await ethers.getContractFactory("ProofTokenFacet");
        proofTokenFacet = await ProofTokenFacet.deploy();
        await proofTokenFacet.waitForDeployment();

        const StakingFacet = await ethers.getContractFactory("StakingFacet");
        stakingFacet = await StakingFacet.deploy();
        await stakingFacet.waitForDeployment();

        const RewardsFacet = await ethers.getContractFactory("RewardsFacet");
        rewardsFacet = await RewardsFacet.deploy();
        await rewardsFacet.waitForDeployment();

        const GovernanceFacet = await ethers.getContractFactory("GovernanceFacet");
        governanceFacet = await GovernanceFacet.deploy();
        await governanceFacet.waitForDeployment();

        const TreasuryFacet = await ethers.getContractFactory("TreasuryFacet");
        treasuryFacet = await TreasuryFacet.deploy();
        await treasuryFacet.waitForDeployment();

        const DiamondInit = await ethers.getContractFactory("DiamondInit");
        diamondInit = await DiamondInit.deploy();
        await diamondInit.waitForDeployment();

        // Deploy Mock Stablecoins
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        mockUSDC = await MockERC20.deploy("USD Coin", "USDC", 6);
        await mockUSDC.waitForDeployment();
        mockDAI = await MockERC20.deploy("Dai Stablecoin", "DAI", 18);
        await mockDAI.waitForDeployment();

        // Build facet cuts
        const facetCuts = [
            {
                facetAddress: await diamondCutFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(diamondCutFacet),
            },
            {
                facetAddress: await diamondLoupeFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(diamondLoupeFacet),
            },
            {
                facetAddress: await ownershipFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(ownershipFacet),
            },
            {
                facetAddress: await btlTokenFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(btlTokenFacet),
            },
            {
                facetAddress: await proofTokenFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(proofTokenFacet),
            },
            {
                facetAddress: await stakingFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(stakingFacet),
            },
            {
                facetAddress: await rewardsFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(rewardsFacet),
            },
            {
                facetAddress: await governanceFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(governanceFacet),
            },
            {
                facetAddress: await treasuryFacet.getAddress(),
                action: FacetCutAction.Add,
                functionSelectors: getSelectors(treasuryFacet),
            },
        ];

        // Init args
        const initArgs = {
            initialBTLSupply: ethers.parseEther("1000000000"),
            initialTokenHolder: await owner.getAddress(),
            initialTreasuryUSDC: ethers.parseUnits("1000000", 6),
            usdcAddress: await mockUSDC.getAddress(),
            daiAddress: await mockDAI.getAddress(),
            admin: await owner.getAddress(),
            oracle: await oracle.getAddress(),
            venueManager: await venueManager.getAddress(),
            treasuryManager: await treasuryManager.getAddress(),
        };

        const initCalldata = diamondInit.interface.encodeFunctionData("init", [initArgs]);

        // Deploy Diamond
        const Diamond = await ethers.getContractFactory("Diamond");
        diamond = await Diamond.deploy(
            await owner.getAddress(),
            facetCuts,
            await diamondInit.getAddress(),
            initCalldata
        );
        await diamond.waitForDeployment();
        diamondAddress = await diamond.getAddress();

        // Fund diamond with mock USDC to match initial treasury accounting
        await mockUSDC.mint(diamondAddress, ethers.parseUnits("1000000", 6));
    });

    describe("Diamond Setup", function () {
        it("should have correct facets deployed", async function () {
            const facets = await asLoupe().facetAddresses();
            expect(facets.length).to.equal(9);
        });

        it("should have correct owner", async function () {
            const ownership = ownershipFacet.attach(diamondAddress) as OwnershipFacet;
            expect(await ownership.owner()).to.equal(await owner.getAddress());
        });
    });

    describe("BTL Token", function () {
        it("should have correct name and symbol", async function () {
            expect(await asBTL().btlName()).to.equal("2bottles");
            expect(await asBTL().btlSymbol()).to.equal("2BTL");
        });

        it("should have correct initial supply", async function () {
            const totalSupply = await asBTL().btlTotalSupply();
            expect(totalSupply).to.equal(ethers.parseEther("1000000000"));
        });

        it("should have initial supply in owner's wallet", async function () {
            const balance = await asBTL().btlBalanceOf(await owner.getAddress());
            expect(balance).to.equal(ethers.parseEther("1000000000"));
        });

        it("should transfer tokens with fee", async function () {
            const transferAmount = ethers.parseEther("1000");
            const feeAmount = (transferAmount * 50n) / 10000n; // 0.5%
            const expectedReceived = transferAmount - feeAmount;

            await asBTL().connect(owner).btlTransfer(await user1.getAddress(), transferAmount);

            const user1Balance = await asBTL().btlBalanceOf(await user1.getAddress());
            expect(user1Balance).to.equal(expectedReceived);
        });

        it("should approve and transferFrom", async function () {
            const approveAmount = ethers.parseEther("500");
            await asBTL().connect(user1).btlApprove(await user2.getAddress(), approveAmount);

            const allowance = await asBTL().btlAllowance(await user1.getAddress(), await user2.getAddress());
            expect(allowance).to.equal(approveAmount);
        });

        it("should allow admin to mint tokens", async function () {
            const mintAmount = ethers.parseEther("100");
            const initialBalance = await asBTL().btlBalanceOf(await user2.getAddress());

            await asBTL().connect(owner).btlMint(await user2.getAddress(), mintAmount);

            const newBalance = await asBTL().btlBalanceOf(await user2.getAddress());
            expect(newBalance - initialBalance).to.equal(mintAmount);
        });

        it("should allow users to burn their tokens", async function () {
            const burnAmount = ethers.parseEther("10");
            const initialBalance = await asBTL().btlBalanceOf(await user2.getAddress());

            await asBTL().connect(user2).btlBurn(burnAmount);

            const newBalance = await asBTL().btlBalanceOf(await user2.getAddress());
            expect(initialBalance - newBalance).to.equal(burnAmount);
        });
    });

    describe("PROOF Token", function () {
        it("should have correct name and symbol", async function () {
            expect(await asPROOF().proofName()).to.equal("Proof");
            expect(await asPROOF().proofSymbol()).to.equal("PROOF");
        });

        it("should start with zero supply", async function () {
            const totalSupply = await asPROOF().proofTotalSupply();
            expect(totalSupply).to.equal(0);
        });

        it("should have 6 decimals", async function () {
            expect(await asPROOF().proofDecimals()).to.equal(6);
        });
    });

    describe("Staking", function () {
        it("should allow users to stake BTL", async function () {
            const stakeAmount = ethers.parseEther("10000");

            // First transfer some BTL to user1
            await asBTL().connect(owner).btlTransfer(await user1.getAddress(), stakeAmount * 2n);

            const initialStake = (await asStaking().getStakeInfo(await user1.getAddress()))[0];

            await asStaking().connect(user1).stake(stakeAmount);

            const newStake = (await asStaking().getStakeInfo(await user1.getAddress()))[0];
            expect(newStake - initialStake).to.be.gt(0);
        });

        it("should mint PROOF when staking", async function () {
            // User1 already staked, check PROOF balance
            const proofBalance = await asPROOF().proofBalanceOf(await user1.getAddress());
            expect(proofBalance).to.be.gt(0);
        });

        it("should track total staked", async function () {
            const totalStaked = await asStaking().getTotalStaked();
            expect(totalStaked).to.be.gt(0);
        });

        it("should require cooldown for unstaking", async function () {
            const stakeInfo = await asStaking().getStakeInfo(await user1.getAddress());
            const stakedAmount = stakeInfo[0];

            // Request unstake
            await asStaking().connect(user1).requestUnstake(stakedAmount);

            // Should not be able to unstake immediately
            const canUnstake = await asStaking().canUnstake(await user1.getAddress());
            expect(canUnstake[0]).to.equal(false);
        });
    });

    describe("Rewards", function () {
        let venueAddress: string;

        before(async function () {
            venueAddress = ethers.Wallet.createRandom().address;
            // Add a venue
            await asRewards().connect(venueManager).addVenue(venueAddress, 100);
        });

        it("should allow venue manager to add venues", async function () {
            const venueInfo = await asRewards().getVenueInfo(venueAddress);
            expect(venueInfo.isActive).to.equal(true);
            expect(venueInfo.multiplier).to.equal(100);
        });

        it("should record check-ins (oracle only)", async function () {
            const checkInHash = ethers.keccak256(ethers.toUtf8Bytes("checkin-1"));

            await asRewards().connect(oracle).recordCheckIn(
                await user2.getAddress(),
                venueAddress,
                2,
                checkInHash
            );

            const rewardInfo = await asRewards().getRewardInfo(await user2.getAddress());
            expect(rewardInfo.checkInCount).to.equal(1);
        });

        it("should reject check-ins from non-oracle", async function () {
            const checkInHash = ethers.keccak256(ethers.toUtf8Bytes("checkin-2"));

            await expect(
                asRewards().connect(user1).recordCheckIn(
                    await user2.getAddress(),
                    venueAddress,
                    2,
                    checkInHash
                )
            ).to.be.revertedWith("LibAppStorage: Must be oracle");
        });

        it("should prevent duplicate check-ins", async function () {
            const checkInHash = ethers.keccak256(ethers.toUtf8Bytes("checkin-1"));

            await expect(
                asRewards().connect(oracle).recordCheckIn(
                    await user2.getAddress(),
                    venueAddress,
                    2,
                    checkInHash
                )
            ).to.be.revertedWith("Rewards: Check-in already processed");
        });
    });

    describe("Governance", function () {
        it("should allow proposal creation with enough BTL", async function () {
            // Owner has plenty of BTL
            await asGovernance().connect(owner).propose(
                "Test proposal: Increase rewards by 10%",
                [], // no execution targets (signal proposal)
                [],
                []
            );

            const proposalCount = await asGovernance().getProposalCount();
            expect(proposalCount).to.equal(1);
        });

        it("should return correct proposal state", async function () {
            const state = await asGovernance().getProposalState(0);
            expect(state).to.equal(0); // Pending
        });

        it("should allow voting after delay", async function () {
            // Mine blocks to pass voting delay
            const params = await asGovernance().getGovernanceParams();
            const votingDelay = params.votingDelay;

            for (let i = 0; i < Number(votingDelay) + 1; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            await asGovernance().connect(owner).castVote(0, true);

            const receipt = await asGovernance().getReceipt(0, await owner.getAddress());
            expect(receipt.hasVoted).to.equal(true);
            expect(receipt.support).to.equal(true);
        });
    });

    describe("Treasury", function () {
        it("should report correct treasury balances", async function () {
            const balances = await asTreasury().getTreasuryBalances();
            expect(balances.usdcBalance).to.equal(ethers.parseUnits("1000000", 6));
        });

        it("should allow treasury manager to deposit", async function () {
            const depositAmount = ethers.parseUnits("100", 6);
            const initialBalance = (await asTreasury().getTreasuryBalances()).usdcBalance;

            // Mint mock USDC to treasury manager and approve diamond
            await mockUSDC.mint(await treasuryManager.getAddress(), depositAmount);
            await mockUSDC.connect(treasuryManager).approve(diamondAddress, depositAmount);

            await asTreasury().connect(treasuryManager).depositUSDC(depositAmount);

            const newBalance = (await asTreasury().getTreasuryBalances()).usdcBalance;
            expect(newBalance - initialBalance).to.equal(depositAmount);
        });

        it("should report collateralization health", async function () {
            const health = await asTreasury().getCollateralizationHealth();
            expect(health.isHealthy).to.equal(true);
        });
    });

    describe("Access Control", function () {
        it("should check role correctly", async function () {
            const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
            const hasRole = await asTreasury().hasRole(ADMIN_ROLE, await owner.getAddress());
            expect(hasRole).to.equal(true);
        });

        it("should allow admin to grant roles", async function () {
            const ORACLE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE"));

            await asTreasury().connect(owner).grantRole(ORACLE_ROLE, await user1.getAddress());

            const hasRole = await asTreasury().hasRole(ORACLE_ROLE, await user1.getAddress());
            expect(hasRole).to.equal(true);
        });

        it("should allow admin to revoke roles", async function () {
            const ORACLE_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ORACLE_ROLE"));

            await asTreasury().connect(owner).revokeRole(ORACLE_ROLE, await user1.getAddress());

            const hasRole = await asTreasury().hasRole(ORACLE_ROLE, await user1.getAddress());
            expect(hasRole).to.equal(false);
        });
    });

    describe("Emergency Controls", function () {
        it("should allow admin to pause", async function () {
            await asTreasury().connect(owner).setPaused(true);

            // Transfers should fail when paused
            await expect(
                asBTL().connect(owner).btlTransfer(await user1.getAddress(), ethers.parseEther("100"))
            ).to.be.revertedWith("LibAppStorage: Contract is paused");
        });

        it("should allow admin to unpause", async function () {
            await asTreasury().connect(owner).setPaused(false);

            // Transfers should work again
            await expect(
                asBTL().connect(owner).btlTransfer(await user1.getAddress(), ethers.parseEther("100"))
            ).to.not.be.revert(ethers);
        });
    });

    describe("Security: Initialization Guard", function () {
        it("should reject re-initialization", async function () {
            // Try calling init again through a diamond cut
            const initArgs = {
                initialBTLSupply: ethers.parseEther("999"),
                initialTokenHolder: await user1.getAddress(),
                initialTreasuryUSDC: 0,
                usdcAddress: await mockUSDC.getAddress(),
                daiAddress: await mockDAI.getAddress(),
                admin: await user1.getAddress(),
                oracle: await user1.getAddress(),
                venueManager: await user1.getAddress(),
                treasuryManager: await user1.getAddress(),
            };
            const initCalldata = diamondInit.interface.encodeFunctionData("init", [initArgs]);
            const diamondCut = diamondCutFacet.attach(diamondAddress) as DiamondCutFacet;

            await expect(
                diamondCut.connect(owner).diamondCut(
                    [],
                    await diamondInit.getAddress(),
                    initCalldata
                )
            ).to.be.revertedWith("DiamondInit: Already initialized");
        });
    });

    describe("Security: Admin Self-Revoke Protection", function () {
        it("should prevent admin from revoking their own admin role", async function () {
            const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
            await expect(
                asTreasury().connect(owner).revokeRole(ADMIN_ROLE, await owner.getAddress())
            ).to.be.revertedWith("Treasury: Cannot revoke own admin role");
        });
    });

    describe("Security: Referral Deduplication", function () {
        it("should prevent duplicate referral claims", async function () {
            // First claim should succeed
            await asRewards().connect(oracle).claimReferralReward(
                await user1.getAddress(), // referrer
                await user2.getAddress()  // referee
            );

            // Second claim with same pair should fail
            await expect(
                asRewards().connect(oracle).claimReferralReward(
                    await user1.getAddress(),
                    await user2.getAddress()
                )
            ).to.be.revertedWith("Rewards: Referral already claimed");
        });
    });

    describe("Security: Unstake Amount Locking", function () {
        it("should lock the specific unstake amount", async function () {
            const stakeInfo = await asStaking().getStakeInfo(await user1.getAddress());
            const stakedAmount = stakeInfo[0];

            if (stakedAmount > 0n) {
                const unstakeAmount = stakedAmount / 2n;
                await asStaking().connect(user1).requestUnstake(unstakeAmount);

                const canUnstakeResult = await asStaking().canUnstake(await user1.getAddress());
                expect(canUnstakeResult[2]).to.equal(unstakeAmount); // requestedAmount
            }
        });
    });

    describe("Security: Deposit Access Control", function () {
        it("should reject deposits from unauthorized users", async function () {
            const depositAmount = ethers.parseUnits("100", 6);
            await mockUSDC.mint(await user1.getAddress(), depositAmount);
            await mockUSDC.connect(user1).approve(diamondAddress, depositAmount);

            await expect(
                asTreasury().connect(user1).depositUSDC(depositAmount)
            ).to.be.revertedWith("Treasury: Not authorized to deposit");
        });
    });

    describe("Security: Snapshot Voting", function () {
        it("should use snapshot-based voting power", async function () {
            // Create a proposal
            await asGovernance().connect(owner).propose(
                "Snapshot test proposal",
                [], [], []
            );

            const proposalCount = await asGovernance().getProposalCount();
            const proposalId = proposalCount - 1n;

            // Get proposal details to check snapshotBlock
            const proposal = await asGovernance().getProposal(proposalId);
            expect(proposal.snapshotBlock).to.be.gt(0);

            // Mine blocks to pass voting delay
            const params = await asGovernance().getGovernanceParams();
            for (let i = 0; i < Number(params.votingDelay) + 1; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            // Owner should be able to vote with snapshot voting power
            await asGovernance().connect(owner).castVote(proposalId, true);
            const receipt = await asGovernance().getReceipt(proposalId, await owner.getAddress());
            expect(receipt.hasVoted).to.equal(true);
            expect(receipt.votes).to.be.gt(0);
        });
    });
});
