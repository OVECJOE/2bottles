// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";

/**
 * @title GovernanceFacet
 * @notice DAO governance for 2bottles protocol
 * @dev Token holders can create and vote on proposals
 *      
 *      GOVERNANCE PROCESS:
 *      1. User creates proposal (needs minimum 2BTL)
 *      2. Voting delay (e.g., 1 day)
 *      3. Voting period (e.g., 3 days)
 *      4. If quorum reached and majority yes → proposal passes
 *      5. Admin executes proposal
 *      
 *      VOTING POWER:
 *      - 1 2BTL = 1 vote
 *      - Can delegate votes to others
 */
contract GovernanceFacet {
    
    // ============ Events ============
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 startBlock,
        uint256 endBlock
    );
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        bool support,
        uint256 votes
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    // ============ Proposal Functions ============

    /**
     * @notice Create a new proposal
     * @param description Description of the proposal
     * @return proposalId The ID of the created proposal
     */
    function propose(string memory description) external returns (uint256 proposalId) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(bytes(description).length > 0, "Governance: Empty description");
        require(s.btlBalances[msg.sender] >= s.proposalThreshold, "Governance: Below proposal threshold");
        
        proposalId = s.proposalCount++;
        
        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];
        proposal.proposer = msg.sender;
        proposal.description = description;
        proposal.startBlock = block.number + s.votingDelay;
        proposal.endBlock = proposal.startBlock + s.votingPeriod;
        proposal.forVotes = 0;
        proposal.againstVotes = 0;
        proposal.executed = false;
        proposal.canceled = false;
        
        emit ProposalCreated(
            proposalId,
            msg.sender,
            description,
            proposal.startBlock,
            proposal.endBlock
        );
    }

    /**
     * @notice Cast a vote on a proposal
     * @param proposalId The proposal to vote on
     * @param support True for yes, false for no
     */
    function castVote(uint256 proposalId, bool support) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(proposalId < s.proposalCount, "Governance: Invalid proposal");
        
        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];
        require(!proposal.executed, "Governance: Proposal already executed");
        require(!proposal.canceled, "Governance: Proposal canceled");
        require(block.number >= proposal.startBlock, "Governance: Voting not started");
        require(block.number <= proposal.endBlock, "Governance: Voting ended");
        
        LibAppStorage.Receipt storage receipt = s.receipts[proposalId][msg.sender];
        require(!receipt.hasVoted, "Governance: Already voted");
        
        // Get voting power (current 2BTL balance)
        uint256 votes = s.btlBalances[msg.sender];
        require(votes > 0, "Governance: No voting power");
        
        // Record vote
        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;
        
        // Update proposal tallies
        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }
        
        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    /**
     * @notice Execute a passed proposal
     */
    function execute(uint256 proposalId) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.ADMIN_ROLE][msg.sender], "Governance: Only admin can execute");
        require(proposalId < s.proposalCount, "Governance: Invalid proposal");
        
        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];
        require(!proposal.executed, "Governance: Already executed");
        require(!proposal.canceled, "Governance: Proposal canceled");
        require(block.number > proposal.endBlock, "Governance: Voting not ended");
        
        // Check quorum
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        require(totalVotes >= s.quorumVotes, "Governance: Quorum not reached");
        
        // Check majority
        require(proposal.forVotes > proposal.againstVotes, "Governance: Proposal defeated");
        
        proposal.executed = true;
        
        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal
     */
    function cancel(uint256 proposalId) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(proposalId < s.proposalCount, "Governance: Invalid proposal");
        
        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];
        require(!proposal.executed, "Governance: Already executed");
        require(!proposal.canceled, "Governance: Already canceled");
        require(
            msg.sender == proposal.proposer || s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "Governance: Not authorized"
        );
        
        proposal.canceled = true;
        
        emit ProposalCanceled(proposalId);
    }

    // ============ Delegation Functions ============

    /**
     * @notice Delegate your voting power to another address
     */
    function delegate(address delegatee) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(delegatee != address(0), "Governance: Cannot delegate to zero address");
        
        address currentDelegate = s.delegates[msg.sender];
        require(delegatee != currentDelegate, "Governance: Already delegated to this address");
        
        s.delegates[msg.sender] = delegatee;
        
        _moveDelegates(currentDelegate, delegatee, s.btlBalances[msg.sender]);
        
        emit DelegateChanged(msg.sender, currentDelegate, delegatee);
    }

    /**
     * @notice Get the current delegate for an address
     */
    function getCurrentDelegate(address delegator) external view returns (address) {
        return LibAppStorage.appStorage().delegates[delegator];
    }

    /**
     * @notice Get current votes for an address (including delegated)
     */
    function getCurrentVotes(address account) external view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 nCheckpoints = s.numCheckpoints[account];
        return nCheckpoints > 0 ? s.checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    // ============ View Functions ============

    /**
     * @notice Get proposal details
     */
    function getProposal(uint256 proposalId) external view returns (
        address proposer,
        string memory description,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 startBlock,
        uint256 endBlock,
        bool executed,
        bool canceled
    ) {
        require(proposalId < LibAppStorage.appStorage().proposalCount, "Governance: Invalid proposal");
        
        LibAppStorage.Proposal storage p = LibAppStorage.appStorage().proposals[proposalId];
        return (
            p.proposer,
            p.description,
            p.forVotes,
            p.againstVotes,
            p.startBlock,
            p.endBlock,
            p.executed,
            p.canceled
        );
    }

    /**
     * @notice Get a user's vote receipt for a proposal
     */
    function getReceipt(uint256 proposalId, address voter) external view returns (
        bool hasVoted,
        bool support,
        uint256 votes
    ) {
        LibAppStorage.Receipt storage receipt = LibAppStorage.appStorage().receipts[proposalId][voter];
        return (receipt.hasVoted, receipt.support, receipt.votes);
    }

    /**
     * @notice Get proposal state
     * @return 0=Pending, 1=Active, 2=Defeated, 3=Succeeded, 4=Executed, 5=Canceled
     */
    function getProposalState(uint256 proposalId) external view returns (uint8) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(proposalId < s.proposalCount, "Governance: Invalid proposal");
        
        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];
        
        if (proposal.canceled) {
            return 5; // Canceled
        } else if (proposal.executed) {
            return 4; // Executed
        } else if (block.number <= proposal.startBlock) {
            return 0; // Pending
        } else if (block.number <= proposal.endBlock) {
            return 1; // Active
        } else {
            // Voting ended, check result
            uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
            if (totalVotes < s.quorumVotes || proposal.forVotes <= proposal.againstVotes) {
                return 2; // Defeated
            } else {
                return 3; // Succeeded
            }
        }
    }

    /**
     * @notice Get governance parameters
     */
    function getGovernanceParams() external view returns (
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumVotes
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        return (
            s.votingDelay,
            s.votingPeriod,
            s.proposalThreshold,
            s.quorumVotes
        );
    }

    /**
     * @notice Get total proposal count
     */
    function getProposalCount() external view returns (uint256) {
        return LibAppStorage.appStorage().proposalCount;
    }

    // ============ Admin Functions ============

    /**
     * @notice Set governance parameters
     */
    function setGovernanceParams(
        uint256 votingDelay_,
        uint256 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumVotes_
    ) external {
        LibAppStorage.enforceIsAdmin();        
        require(votingDelay_ >= 1 && votingDelay_ <= 50400, "Governance: Invalid voting delay");
        require(votingPeriod_ >= 5760 && votingPeriod_ <= 100800, "Governance: Invalid voting period");
        require(proposalThreshold_ > 0, "Governance: Invalid proposal threshold");
        require(quorumVotes_ > 0, "Governance: Invalid quorum");
        
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        s.votingDelay = votingDelay_;
        s.votingPeriod = votingPeriod_;
        s.proposalThreshold = proposalThreshold_;
        s.quorumVotes = quorumVotes_;
    }

    // ============ Internal Functions ============

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = uint32(s.numCheckpoints[srcRep]);
                uint256 srcRepOld = srcRepNum > 0 ? s.checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld > amount ? srcRepOld - amount : 0;
                _writeCheckpoint(srcRep, srcRepNum, srcRepNew);
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = uint32(s.numCheckpoints[dstRep]);
                uint256 dstRepOld = dstRepNum > 0 ? s.checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld + amount;
                _writeCheckpoint(dstRep, dstRepNum, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 newVotes
    ) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint32 blockNumber = uint32(block.number);

        if (nCheckpoints > 0 && s.checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            s.checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            s.checkpoints[delegatee][nCheckpoints] = LibAppStorage.Checkpoint(blockNumber, newVotes);
            s.numCheckpoints[delegatee] = nCheckpoints + 1;
        }
    }
}
