// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./libraries/LibDiamond.sol";
import "./interfaces/IDiamondCut.sol";

/**
 * @title Diamond
 * @notice The main 2bottles Diamond contract - the single entry point for all functionality
 * @dev This contract:
 *      1. Receives all function calls
 *      2. Looks up which facet handles that function
 *      3. Delegates the call to that facet using delegatecall
 *      4. Returns the result to the caller
 */
contract Diamond {
    /**
     * @notice Constructor sets up the diamond with initial facets
     * @param _owner The address that will own this diamond
     * @param _diamondCut Array of facets to add on deployment
     * @param _init Address of initialization contract (or address(0))
     * @param _calldata Initialization calldata (or empty bytes)
     */
    constructor(
        address _owner,
        IDiamondCut.FacetCut[] memory _diamondCut,
        address _init,
        bytes memory _calldata
    ) payable {
        LibDiamond.setContractOwner(_owner);
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }

    /**
     * @notice Fallback function - routes all calls to appropriate facets
     */
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: Function does not exist");

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
