//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


contract InvoiceToken is ERC20 {
    uint256 public constant DISCOUNT_RATE = 5; 
    uint256 public immutable maxSupply; 
    address public immutable supplier;
    address public immutable mainContract;
    AggregatorV3Interface internal immutable priceFeed;
    
   
    uint256 public totalPaidToSupplier;
    
    constructor(
        string memory _name, 
        string memory _symbol, 
        uint256 _invoiceAmountUSD, 
        address _supplierAddress,  
        address _mainContractAddress  
    ) ERC20(_name, _symbol) {
        priceFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);
        supplier = _supplierAddress;  
        mainContract = _mainContractAddress;  
        
        
        maxSupply = _invoiceAmountUSD - (_invoiceAmountUSD * DISCOUNT_RATE / 100);
    }
    
    
    function getETHPrice() public view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price from oracle");
        return uint256(price) * 1e10;
    }
    
    
    function getExactCost(uint256 _amount) public view returns (uint256) {
        require(_amount > 0, "Amount must be > 0");
        return (_amount * 1e18) / getETHPrice();
    }
    
    
    function buyTokens(uint256 _amount, address _investor) external payable returns (bool) {
        require(msg.sender == mainContract, "Only main contract can call");
        require(_amount > 0, "Amount must be > 0");
        require(_investor != address(0), "Invalid investor address");
        require(totalSupply() + _amount <= maxSupply, "Exceeds max supply");
        
        uint256 cost = getExactCost(_amount);
        require(msg.value >= cost, "Insufficient ETH");
        
        _mint(_investor, _amount);
        
    
        (bool success,) = payable(supplier).call{value: cost}("");
        require(success, "Payment to supplier failed");
       
        totalPaidToSupplier += cost;
        
        if (msg.value > cost) {
            (bool refundSuccess,) = payable(_investor).call{value: msg.value - cost}("");
            require(refundSuccess, "Refund failed");
        }
        
        return true;
    }
    
    
    function remainingCapacity() external view returns (uint256) {
        return maxSupply - totalSupply();
    }
    
    
    function getOriginalInvoiceAmount() external view returns (uint256) {
        return (maxSupply * 100) / (100 - DISCOUNT_RATE);
    }
}