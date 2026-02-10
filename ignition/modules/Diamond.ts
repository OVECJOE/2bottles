import { createRequire } from "node:module";
import { Interface, FunctionFragment, JsonFragment } from "ethers";
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const require = createRequire(import.meta.url);

const diamondCutFacetArtifact = require(
  "../../artifacts/contracts/facets/DiamondCutFacet.sol/DiamondCutFacet.json"
);
const diamondLoupeFacetArtifact = require(
  "../../artifacts/contracts/facets/DiamondLoupeFacet.sol/DiamondLoupeFacet.json"
);
const ownershipFacetArtifact = require(
  "../../artifacts/contracts/facets/OwnershipFacet.sol/OwnershipFacet.json"
);
const btlTokenFacetArtifact = require(
  "../../artifacts/contracts/facets/BTLTokenFacet.sol/BTLTokenFacet.json"
);
const proofTokenFacetArtifact = require(
  "../../artifacts/contracts/facets/ProofTokenFacet.sol/ProofTokenFacet.json"
);
const stakingFacetArtifact = require(
  "../../artifacts/contracts/facets/StakingFacet.sol/StakingFacet.json"
);
const rewardsFacetArtifact = require(
  "../../artifacts/contracts/facets/RewardsFacet.sol/RewardsFacet.json"
);
const governanceFacetArtifact = require(
  "../../artifacts/contracts/facets/GovernanceFacet.sol/GovernanceFacet.json"
);
const treasuryFacetArtifact = require(
  "../../artifacts/contracts/facets/TreasuryFacet.sol/TreasuryFacet.json"
);

type ArtifactLike = { abi: JsonFragment[] };

function isInitFunction(fragment: FunctionFragment): boolean {
  return (
    fragment.name === "init" &&
    fragment.inputs.length === 1 &&
    fragment.inputs[0]?.baseType === "tuple"
  );
}

function getSelectorsFromAbi(artifact: ArtifactLike): string[] {
  const iface = new Interface(artifact.abi);

  return iface.fragments
    .filter((fragment): fragment is FunctionFragment => fragment.type === "function")
    .filter((fragment) => !isInitFunction(fragment))
    .map((fragment) => fragment.selector)
    .filter((selector): selector is string => selector !== null);
}

const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 } as const;

const DiamondModule = buildModule("DiamondModule", (m) => {
  const deployer = m.getAccount(0);

  const oracle = m.getParameter("oracleAddress", deployer);
  const venueManager = m.getParameter("venueManagerAddress", deployer);
  const treasuryManager = m.getParameter("treasuryManagerAddress", deployer);

  const initialBTLSupply = m.getParameter(
    "initialBTLSupply",
    1_000_000_000n * 10n ** 18n
  );
  const initialTreasuryUSDC = m.getParameter(
    "initialTreasuryUSDC",
    1_000_000n * 10n ** 6n
  );
  const usdcAddress = m.getParameter(
    "usdcAddress",
    "0x0000000000000000000000000000000000000001"
  );
  const daiAddress = m.getParameter(
    "daiAddress",
    "0x0000000000000000000000000000000000000002"
  );

  const diamondCutFacet = m.contract("DiamondCutFacet");
  const diamondLoupeFacet = m.contract("DiamondLoupeFacet");
  const ownershipFacet = m.contract("OwnershipFacet");
  const btlTokenFacet = m.contract("BTLTokenFacet");
  const proofTokenFacet = m.contract("ProofTokenFacet");
  const stakingFacet = m.contract("StakingFacet");
  const rewardsFacet = m.contract("RewardsFacet");
  const governanceFacet = m.contract("GovernanceFacet");
  const treasuryFacet = m.contract("TreasuryFacet");
  const diamondInit = m.contract("DiamondInit");

  const facetCuts = [
    {
      facetAddress: diamondCutFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(diamondCutFacetArtifact),
    },
    {
      facetAddress: diamondLoupeFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(diamondLoupeFacetArtifact),
    },
    {
      facetAddress: ownershipFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(ownershipFacetArtifact),
    },
    {
      facetAddress: btlTokenFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(btlTokenFacetArtifact),
    },
    {
      facetAddress: proofTokenFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(proofTokenFacetArtifact),
    },
    {
      facetAddress: stakingFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(stakingFacetArtifact),
    },
    {
      facetAddress: rewardsFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(rewardsFacetArtifact),
    },
    {
      facetAddress: governanceFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(governanceFacetArtifact),
    },
    {
      facetAddress: treasuryFacet,
      action: FacetCutAction.Add,
      functionSelectors: getSelectorsFromAbi(treasuryFacetArtifact),
    },
  ];

  const initArgs = {
    initialBTLSupply,
    initialTokenHolder: deployer,
    initialTreasuryUSDC,
    usdcAddress,
    daiAddress,
    admin: deployer,
    oracle,
    venueManager,
    treasuryManager,
  };

  const initCalldata = m.encodeFunctionCall(diamondInit, "init", [initArgs]);

  const diamond = m.contract("Diamond", [
    deployer,
    facetCuts,
    diamondInit,
    initCalldata,
  ]);

  return {
    diamond,
    diamondCutFacet,
    diamondLoupeFacet,
    ownershipFacet,
    btlTokenFacet,
    proofTokenFacet,
    stakingFacet,
    rewardsFacet,
    governanceFacet,
    treasuryFacet,
    diamondInit,
  };
});

export default DiamondModule;
