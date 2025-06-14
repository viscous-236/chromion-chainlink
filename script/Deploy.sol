// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/main.sol";
import "../src/InvoiceToken.sol";

contract DeployScript is Script {
    function run() external {
        
        // Network-specific configurations
        address router;
        bytes32 donId;
        
        // Get the chain ID to determine network-specific values
        uint256 chainId = block.chainid;
        
        if (chainId == 11155111) { // Sepolia
            router = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
            donId = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000; // fun-ethereum-sepolia-1
        } else if (chainId == 80002) { // Polygon Amoy
            router = 0xC22a79eBA640940ABB6dF0f7982cc119578E11De;
            donId = 0x66756e2d706f6c79676f6e2d616d6f792d310000000000000000000000000000; // fun-polygon-amoy-1
        } else if (chainId == 43113) { // Avalanche Fuji
            router = 0xA9d587a00A31A52Ed70D6026794a8FC5E2F5dCb0;
            donId = 0x66756e2d6176616c616e6368652d66756a692d31000000000000000000000000; // fun-avalanche-fuji-1
        } else if (chainId == 84532) { // Base Sepolia
            router = 0xf9B8fc078197181C841c296C876945aaa425B278;
            donId = 0x66756e2d626173652d7365706f6c69612d310000000000000000000000000000; // fun-base-sepolia-1
        } else {
            revert("Unsupported network");
        }
        
        // Your Chainlink Functions subscription ID
        uint64 subscriptionId = 4984;
        
        vm.startBroadcast();
        
        // Deploy the Main contract
        Main mainContract = new Main(router, subscriptionId, donId);
        
        console.log("Main contract deployed at:", address(mainContract));
        console.log("Router:", router);
        console.log("DON ID:", vm.toString(donId));
        console.log("Subscription ID:", subscriptionId);
        
        vm.stopBroadcast();
    }
}