// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./LibAppStorage.sol";

/**
 * @title LibVotes
 * @notice Shared voting checkpoint logic for the Diamond
 * @dev Implements Compound-style vote checkpointing that tracks effective voting power.
 *
 *      VOTING POWER RULES:
 *      - If an account has NOT delegated: their own BTL balance = their voting power
 *      - If an account HAS delegated to X: X gets those votes, the delegator gets 0
 *      - Checkpoints record voting power at each block for historical lookups
 *
 *      MUST be called on every BTL balance change (transfer, mint, burn)
 *      to keep voting power accurate.
 */
library LibVotes {
    /**
     * @notice Update voting power after a BTL balance change (transfer/mint/burn)
     * @param from Source address (address(0) for minting)
     * @param to Destination address (address(0) for burning)
     * @param amount Amount of BTL transferred
     */
    function transferVotingUnits(address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();

        // Determine the effective representative for from/to
        address fromRep;
        address toRep;

        if (from != address(0)) {
            // If delegated, votes move from the delegate; otherwise from the account itself
            fromRep = s.delegates[from] != address(0) ? s.delegates[from] : from;
        }
        if (to != address(0)) {
            toRep = s.delegates[to] != address(0) ? s.delegates[to] : to;
        }

        _moveVotingPower(fromRep, toRep, amount);
    }

    /**
     * @notice Handle delegation change — move all voting power from old to new delegate
     * @param delegator The account changing delegation
     * @param oldDelegatee Previous delegate (address(0) means self-represented)
     * @param newDelegatee New delegate
     */
    function delegateVotingPower(
        address delegator,
        address oldDelegatee,
        address newDelegatee
    ) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 amount = s.btlBalances[delegator];
        if (amount == 0) return;

        // Resolve address(0) to delegator (self-representation)
        address fromRep = oldDelegatee != address(0) ? oldDelegatee : delegator;
        address toRep = newDelegatee != address(0) ? newDelegatee : delegator;

        _moveVotingPower(fromRep, toRep, amount);
    }

    /**
     * @notice Get voting power of an account at a specific past block
     * @dev Binary-searches the checkpoint array for the most recent checkpoint <= blockNumber
     * @param account The address to get voting power for
     * @param blockNumber The block number to check (must be in the past)
     * @return The amount of voting power at that block
     */
    function getPriorVotes(address account, uint256 blockNumber) internal view returns (uint256) {
        require(blockNumber < block.number, "LibVotes: block not yet mined");

        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 nCheckpoints = s.numCheckpoints[account];

        if (nCheckpoints == 0) return 0;

        // Shortcut: most recent checkpoint is before or at the target block
        if (s.checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return s.checkpoints[account][nCheckpoints - 1].votes;
        }

        // Shortcut: first checkpoint is after the target block
        if (s.checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        // Binary search
        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            if (s.checkpoints[account][center].fromBlock <= blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return s.checkpoints[account][lower].votes;
    }

    /**
     * @notice Get current voting power of an account
     * @param account The address to check
     * @return Current voting power
     */
    function getCurrentVotes(address account) internal view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 nCheckpoints = s.numCheckpoints[account];
        return nCheckpoints > 0 ? s.checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    // ============ Internal ============

    function _moveVotingPower(address from, address to, uint256 amount) private {
        if (from == to || amount == 0) return;

        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();

        if (from != address(0)) {
            uint32 nCheckpoints = uint32(s.numCheckpoints[from]);
            uint256 oldVotes = nCheckpoints > 0
                ? s.checkpoints[from][nCheckpoints - 1].votes
                : 0;
            uint256 newVotes = oldVotes > amount ? oldVotes - amount : 0;
            _writeCheckpoint(from, nCheckpoints, newVotes);
        }

        if (to != address(0)) {
            uint32 nCheckpoints = uint32(s.numCheckpoints[to]);
            uint256 oldVotes = nCheckpoints > 0
                ? s.checkpoints[to][nCheckpoints - 1].votes
                : 0;
            uint256 newVotes = oldVotes + amount;
            _writeCheckpoint(to, nCheckpoints, newVotes);
        }
    }

    function _writeCheckpoint(
        address account,
        uint32 nCheckpoints,
        uint256 newVotes
    ) private {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint32 blockNumber = uint32(block.number);

        if (
            nCheckpoints > 0 &&
            s.checkpoints[account][nCheckpoints - 1].fromBlock == blockNumber
        ) {
            // Same block: overwrite the last checkpoint
            s.checkpoints[account][nCheckpoints - 1].votes = newVotes;
        } else {
            // New block: write a new checkpoint
            s.checkpoints[account][nCheckpoints] = LibAppStorage.Checkpoint(
                blockNumber,
                newVotes
            );
            s.numCheckpoints[account] = nCheckpoints + 1;
        }
    }
}
