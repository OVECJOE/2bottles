// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IDiamondCut {
    enum FacetCutAction { Add, Replace, Remove }

    // Add = 0, Replace = 1, Remove = 2
    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice Add/replace/remove any number of functions and optionally execute
    ///         a function with delegatecall
    /// @param _cut Contains the facet addresses and function selectors
    /// @param _init The address of the contract or facet to execute _calldata
    /// @param _calldata A function call, including function selector and arguments
    function diamondCut(FacetCut[] calldata _cut, address _init, bytes calldata _calldata) external;

    event DiamondCut(FacetCut[] _cut, address _init, bytes _calldata);
}
