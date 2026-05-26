// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @title Deploy PredictionMarketHook
/// @notice Deploy the Hook contract to X Layer
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url xlayer --broadcast --verify
///
///   Or with private key:
///   forge script script/Deploy.s.sol --rpc-url xlayer --broadcast \
///       --private-key $PRIVATE_KEY
///
///   With verification:
///   forge script script/Deploy.s.sol --rpc-url xlayer --broadcast \
///       --verify --etherscan-api-key $OKX_EXPLORER_API_KEY
contract DeployScript is Script {
    // PoolManager addresses by chain
    // X Layer: the PoolManager must be deployed first or use the official one
    // For hackathon: deploy PoolManager yourself (see DeployPoolManager.s.sol)
    
    address public constant POOL_MANAGER = 0x0000000000000000000000000000000000000000;
    // TODO: Replace with actual PoolManager address on X Layer
    // Check https://docs.uniswap.org/contracts/v4/deployments or deploy your own

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy Hook
        PredictionMarketHook hook = new PredictionMarketHook(
            IPoolManager(POOL_MANAGER)
        );

        vm.stopBroadcast();

        console2.log("========================================");
        console2.log("PredictionMarketHook deployed!");
        console2.log("Address:", address(hook));
        console2.log("========================================");
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Create a Uniswap V4 pool for your token pair");
        console2.log("2. Call hook.createMarket() with the PoolId");
        console2.log("3. Tweet @XLayerOfficial @Uniswap @flapdotsh");
        console2.log("4. Submit Google Form by May 28 23:59 UTC");
        console2.log("");
        console2.log("Pool ID after pool creation:");
        console2.log("  PoolKey(POOL_MANAGER, token0, token1, fee, tickSpacing, address(hook))");
    }
}
