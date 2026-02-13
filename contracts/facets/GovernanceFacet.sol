// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";
import "../libraries/LibVotes.sol";

/**
 * @title GovernanceFacet
 * @notice On-chain DAO governance for the 2bottles protocol
 * @dev Implements Governor-style governance with snapshot-based voting:
 *
 *      LIFECYCLE:
 *      1. `propose()` — Creates a proposal; snapshots voting power at the previous block
 *      2. `castVote()` — Voters commit using their power at the snapshot block
 *      3. `execute()` — Admin triggers on-chain execution if quorum is met
 *
 *      Snapshot voting prevents vote-transfer-vote attacks. Delegation is
 *      connected to the shared LibVotes checkpoint system. Proposals may
 *      optionally carry executable payloads (targets, values, calldatas) for
 *      on-chain parameter changes, or be signal-only with empty arrays.
 */
contract GovernanceFacet {

    // ============ Events ============
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 snapshotBlock,
        uint256 startBlock,
        uint256 endBlock,
        address[] targets,
        uint256[] values,
        bytes[] calldatas
    );
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        bool support,
        uint256 votes
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event DelegateChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );

    // ============ Proposal Functions ============

    /**
     * @notice Create a proposal with optional on-chain execution targets
     * @param description Human-readable description
     * @param targets Target contract addresses for execution (can be empty)
     * @param values ETH values for each call (can be empty)
     * @param calldatas Encoded function calls for each target (can be empty)
     */
    function propose(
        string memory description,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) external returns (uint256 proposalId) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(bytes(description).length > 0, "Governance: Empty description");
        require(
            s.btlBalances[msg.sender] >= s.proposalThreshold,
            "Governance: Below proposal threshold"
        );
        require(
            targets.length == values.length && targets.length == calldatas.length,
            "Governance: Array length mismatch"
        );

        proposalId = s.proposalCount++;

        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];
        proposal.proposer = msg.sender;
        proposal.description = description;
        proposal.snapshotBlock = block.number - 1; // Snapshot at previous block
        proposal.startBlock = block.number + s.votingDelay;
        proposal.endBlock = proposal.startBlock + s.votingPeriod;
        proposal.forVotes = 0;
        proposal.againstVotes = 0;
        proposal.executed = false;
        proposal.canceled = false;

        // Store execution targets (can be empty for "signal" proposals)
        for (uint256 i = 0; i < targets.length; i++) {
            proposal.targets.push(targets[i]);
            proposal.values.push(values[i]);
            proposal.calldatas.push(calldatas[i]);
        }

        emit ProposalCreated(
            proposalId,
            msg.sender,
            description,
            proposal.snapshotBlock,
            proposal.startBlock,
            proposal.endBlock,
            targets,
            values,
            calldatas
        );
    }

    /**
     * @notice Cast a vote on an active proposal
     * @dev Voting power is read from the LibVotes checkpoint at the proposal's
     *      snapshot block, ensuring votes are locked at proposal creation time.
     * @param proposalId The ID of the proposal to vote on
     * @param support True to vote in favor, false to vote against
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

        // Read voting power at the snapshot block (immutable after proposal creation)
        uint256 votes = LibVotes.getPriorVotes(msg.sender, proposal.snapshotBlock);
        require(votes > 0, "Governance: No voting power at snapshot");

        // Record vote
        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }

        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    /**
     * @notice Execute a passed proposal — calls each target with its calldata
     * @dev Only admin can execute. For mainnet, consider using a timelock.
     */
    function execute(uint256 proposalId) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "Governance: Only admin can execute"
        );
        require(proposalId < s.proposalCount, "Governance: Invalid proposal");

        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];
        require(!proposal.executed, "Governance: Already executed");
        require(!proposal.canceled, "Governance: Proposal canceled");
        require(block.number > proposal.endBlock, "Governance: Voting not ended");

        // Check quorum
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        require(totalVotes >= s.quorumVotes, "Governance: Quorum not reached");
        require(proposal.forVotes > proposal.againstVotes, "Governance: Proposal defeated");

        proposal.executed = true;

        // Execute on-chain actions (if any)
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            (bool success, bytes memory returndata) = proposal.targets[i].call{
                value: proposal.values[i]
            }(proposal.calldatas[i]);
            require(success, string(abi.encodePacked("Governance: Execution failed at index ", _toString(i), ": ", returndata)));
        }

        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(proposalId < s.proposalCount, "Governance: Invalid proposal");

        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];
        require(!proposal.executed, "Governance: Already executed");
        require(!proposal.canceled, "Governance: Already canceled");
        require(
            msg.sender == proposal.proposer ||
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "Governance: Not authorized"
        );

        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
    }

    // ============ Delegation Functions ============

    /**
     * @notice Delegate voting power to another address
     * @dev Updates the LibVotes checkpoint system so the delegatee receives
     *      the delegator's full voting weight in future snapshots.
     * @param delegatee The address to delegate voting power to
     */
    function delegate(address delegatee) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(delegatee != address(0), "Governance: Cannot delegate to zero address");

        address currentDelegate = s.delegates[msg.sender];
        require(delegatee != currentDelegate, "Governance: Already delegated to this address");

        s.delegates[msg.sender] = delegatee;

        // Transfer checkpoint voting power from old delegate to new delegate
        LibVotes.delegateVotingPower(msg.sender, currentDelegate, delegatee);

        emit DelegateChanged(msg.sender, currentDelegate, delegatee);
    }

    function getCurrentDelegate(address delegator) external view returns (address) {
        return LibAppStorage.appStorage().delegates[delegator];
    }

    /**
     * @notice Get current voting power (includes delegated votes)
     */
    function getCurrentVotes(address account) external view returns (uint256) {
        return LibVotes.getCurrentVotes(account);
    }

    /**
     * @notice Get voting power at a specific past block
     */
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256) {
        return LibVotes.getPriorVotes(account, blockNumber);
    }

    // ============ View Functions ============

    function getProposal(uint256 proposalId) external view returns (
        address proposer,
        string memory description,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 snapshotBlock,
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
            p.snapshotBlock,
            p.startBlock,
            p.endBlock,
            p.executed,
            p.canceled
        );
    }

    function getProposalActions(uint256 proposalId) external view returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) {
        require(proposalId < LibAppStorage.appStorage().proposalCount, "Governance: Invalid proposal");
        LibAppStorage.Proposal storage p = LibAppStorage.appStorage().proposals[proposalId];
        return (p.targets, p.values, p.calldatas);
    }

    function getReceipt(uint256 proposalId, address voter) external view returns (
        bool hasVoted,
        bool support,
        uint256 votes
    ) {
        LibAppStorage.Receipt storage receipt = LibAppStorage.appStorage().receipts[proposalId][voter];
        return (receipt.hasVoted, receipt.support, receipt.votes);
    }

    /**
     * @return 0=Pending, 1=Active, 2=Defeated, 3=Succeeded, 4=Executed, 5=Canceled
     */
    function getProposalState(uint256 proposalId) external view returns (uint8) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(proposalId < s.proposalCount, "Governance: Invalid proposal");

        LibAppStorage.Proposal storage proposal = s.proposals[proposalId];

        if (proposal.canceled) return 5;
        if (proposal.executed) return 4;
        if (block.number <= proposal.startBlock) return 0;
        if (block.number <= proposal.endBlock) return 1;

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        if (totalVotes < s.quorumVotes || proposal.forVotes <= proposal.againstVotes) {
            return 2; // Defeated
        }
        return 3; // Succeeded
    }

    function getGovernanceParams() external view returns (
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumVotes
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        return (s.votingDelay, s.votingPeriod, s.proposalThreshold, s.quorumVotes);
    }

    function getProposalCount() external view returns (uint256) {
        return LibAppStorage.appStorage().proposalCount;
    }

    // ============ Admin Functions ============

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

    // ============ Internal Helpers ============

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
