// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibDiamond.sol";
import "../interfaces/IDiamondCut.sol";

contract DiamondCutFacet is IDiamondCut {
    using LibDiamond for LibDiamond.DiamondStorage;

    function diamondCut(FacetCut[] calldata _cut, address _init, bytes calldata _calldata) external override {
        LibDiamond.enforceIsContractOwner();
        for (uint i = 0; i < _cut.length; i++) {
            IDiamondCut.FacetCutAction action = _cut[i].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                LibDiamond.addFunctions(_cut[i].facetAddress, _cut[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                LibDiamond.replaceFunctions(_cut[i].facetAddress, _cut[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                // For remove, the facetAddress must be zero per this implementation
                LibDiamond.removeFunctions(address(0), _cut[i].functionSelectors);
            } else {
                revert("DiamondCutFacet: Incorrect FacetCutAction");
            }
        }
        emit DiamondCut(_cut, _init, _calldata);
        LibDiamond.initializeDiamondCut(_init, _calldata);
    }
}
