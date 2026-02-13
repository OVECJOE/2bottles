// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title LibReentrancyGuard
 * @notice Reentrancy protection for Diamond facets
 * @dev Uses a dedicated storage slot to avoid collisions with AppStorage or DiamondStorage.
 *      All state-modifying facet functions that interact with external contracts
 *      MUST use nonReentrantBefore/nonReentrantAfter or the nonReentrant modifier pattern.
 */
library LibReentrancyGuard {
    bytes32 constant REENTRANCY_GUARD_STORAGE = keccak256("2bottles.reentrancy.guard");

    uint256 constant NOT_ENTERED = 1;
    uint256 constant ENTERED = 2;

    struct ReentrancyStorage {
        uint256 status;
    }

    function reentrancyStorage() internal pure returns (ReentrancyStorage storage s) {
        bytes32 position = REENTRANCY_GUARD_STORAGE;
        assembly {
            s.slot := position
        }
    }

    function nonReentrantBefore() internal {
        ReentrancyStorage storage s = reentrancyStorage();
        require(s.status != ENTERED, "ReentrancyGuard: reentrant call");
        s.status = ENTERED;
    }

    function nonReentrantAfter() internal {
        reentrancyStorage().status = NOT_ENTERED;
    }
}
