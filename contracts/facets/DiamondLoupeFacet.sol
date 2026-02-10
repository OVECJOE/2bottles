// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibDiamond.sol";
import "../interfaces/IDiamondLoupe.sol";

contract DiamondLoupeFacet is IDiamondLoupe {
    function facets() external view override returns (Facet[] memory) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numFacets = ds.facetAddresses.length;
        Facet[] memory res = new Facet[](numFacets);
        for (uint i = 0; i < numFacets; i++) {
            address addr = ds.facetAddresses[i];
            res[i].facetAddress = addr;
            res[i].functionSelectors = ds.facetFunctionSelectors[addr];
        }
        return res;
    }

    function facetFunctionSelectors(address _facet) external view override returns (bytes4[] memory) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return ds.facetFunctionSelectors[_facet];
    }

    function facetAddresses() external view override returns (address[] memory) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return ds.facetAddresses;
    }

    function facetAddress(bytes4 _functionSelector) external view override returns (address) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return ds.selectorToFacetAndPosition[_functionSelector].facetAddress;
    }
}
