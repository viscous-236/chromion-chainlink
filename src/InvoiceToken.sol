//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract InvoiceToken is ERC20, Ownable, ReentrancyGuard {
    error InvoiceToken__MoreThanZero();
    error InvoiceToken__NotEnoughTokens();
    error InvoiceToken__NotEnoughEthToBuy();
    error InvoiceToken__PaymentToSupplierFails();

    uint256 public constant DISCOUNT_RATE = 5;
    uint256 public tokenSupply;
    uint256 public constant ONE_DOLLAR = 1e18;
    address public supplier;
    AggregatorV3Interface internal priceFeed;

    modifier MoreThanZero(uint256 _number) {
        if (_number <= 0) {
            revert InvoiceToken__MoreThanZero();
        }
        _;
    }

    constructor(string memory _name, string memory _symbol, uint256 _amount, address _supplier)
        ERC20(_name, _symbol)
        Ownable(_supplier)
        MoreThanZero(_amount)
    {
        priceFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);
        supplier = _supplier;
        tokenSupply = _amount - (_amount * DISCOUNT_RATE / 100);
        _mint(_supplier, tokenSupply);
    }

    function getLatestPrice() public view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        return uint256(answer * 1e10);
    }

    function getTokenPrice() public view returns (uint256) {
        uint256 oneETHPriceUSD = getLatestPrice();
        return (ONE_DOLLAR * 1e18) / oneETHPriceUSD;
    }

    function getExactCost(uint256 _amount) public view MoreThanZero(_amount) returns (uint256) {
        return getTokenPrice() * _amount;
    }

    function buyTokens(uint256 _amount) external payable MoreThanZero(_amount) nonReentrant returns (bool) {
        uint256 totalCost = getExactCost(_amount);

        if (balanceOf(supplier) < _amount) {
            revert InvoiceToken__NotEnoughTokens();
        }
        if (msg.value < totalCost) {
            revert InvoiceToken__NotEnoughEthToBuy();
        }
        _transfer(supplier, msg.sender, _amount);
        (bool success,) = payable(supplier).call{value: totalCost}("");
        if (!success) {
            revert InvoiceToken__PaymentToSupplierFails();
        }
        return success;
    }
}
