//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_3_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_3_0/FunctionsClient.sol";
import {InvoiceToken} from "./InvoiceToken.sol";
import {AutomationCompatible} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

contract Main is FunctionsClient, ReentrancyGuard, AutomationCompatible {
    using FunctionsRequest for FunctionsRequest.Request;

    error Main__MoreThanZero(uint256 _number);
    error Main__MustBeValidAddress(address _address);
    error Main__MustBeUnique();
    error Main__CallerMustBeSupplier();
    error Main__CallerMustBeInvestor();
    error Main__DueDateMustBeInFuture(uint256 _dueDate, uint256 currentTime);
    error Main__InvoiceTokenNotFound();
    error Main__InvoiceMustBeApproved();
    error Main__TokensBuyingFails();
    error Main__RoleAlereadyChosen();
    error Main__InvoiceStatusMustBeVerificationInProgress();
    error Main__InvoiceStatusMustBePending();
    error Main__InvoiceStatusMustBeApproved();
    error Main__InvoiceNotExist();
    error Main__MustBeBuyerOfTheInvoice();
    error Main__CallerMustBeBuyer();
    error Main__InsufficientPayment();
    error Main__InvoiceAlreadyPaid();
    error Main__PaymentDistributionFailed();
    error Main__OnlyAuthorizedUpkeepers();
    error Main__OnlyOwner();
    error Main__ErrorInBurningTokens();

    uint64 private s_subscriptionId;
    bytes32 private s_donId;
    uint32 private s_gasLimit = 300000;
    uint256 public distributionCounter;
    uint256 public nextDistributionToProcess;
    uint256 public totalPendingDistributions;
    uint256 private constant GRACEPERIOD = 2 days;
    uint256 private constant MAX_PENDING_DISTRIBUTIONS = 10;
    uint256 public constant ONE_DOLLAR = 1e18;
    uint256[] public arrayOfInoviceIds;

    address public immutable owner;
    mapping(address => bool) public authorizedUpkeepers;

    enum UserRole {
        Supplier,
        Buyer,
        Investor
    }

    enum InvoiceStatus {
        Pending,
        VerificationInProgress,
        Approved,
        Rejected,
        Paid
    }

    struct Invoice {
        uint256 id;
        address supplier;
        address buyer;
        uint256 amount;
        address[] investors;
        InvoiceStatus status;
        uint256 dueDate;
        uint256 totalInvestment;
        bool isPaid;
    }

    struct PaymentDistribution {
        uint256 invoiceId;
        uint256 totalPayment;
        bool processed;
        uint256 timestamp;
    }

    mapping(uint256 id => mapping(address investor => uint256 amountOfTokensPurchased)) public
        amountOfTokensPurchasedByInvestor;
    mapping(uint256 id => Invoice invoice) public invoices;
    mapping(uint256 id => bool) public IdExists;
    mapping(address user => UserRole role) public userRole;
    mapping(uint256 id => address token) public invoiceToken;
    mapping(address => bool) public hasChosenRole;
    mapping(bytes32 => uint256) public pendingRequests;
    mapping(address buyer => uint256[] invoiceIds) public buyerInvoices;
    mapping(address supplier => uint256[] invoicesIds) public supplierInvoices;
    mapping(uint256 id => PaymentDistribution distribution) public pendingDistributions;

    event ContractFunded(address indexed sender, uint256 amount);
    event InvoiceCreated(
        uint256 indexed id, address indexed supplier, address indexed buyer, uint256 amount, uint256 dueDate
    );
    event SuccessfulTokenPurchase(uint256 indexed invoiceId, address indexed buyer, uint256 amount);
    event InvoiceVerificationRequested(uint256 indexed invoiceId, bytes32 requestId);
    event InvoiceVerified(uint256 indexed invoiceId, bool isValid);
    event PaymentReceived(uint256 indexed invoiceId, address indexed buyer, uint256 amount);
    event InvoicePaid(uint256 indexed invoiceId, uint256 amount);
    event PaymentDistributed(uint256 indexed invoiceId, address indexed receiver, uint256 amount);
    event PaymentToSupplier(uint256 indexed invoiceId, address indexed supplier, uint256 amount);
    event InvoiceTokenCreated(uint256 indexed invoiceId, address indexed tokenAddress);
    event UpkeeperAuthorized(address indexed upkeeper);
    event UpkeeperRevoked(address indexed upkeeper);
    event AllTokensBurned(uint256 indexed invoiceId, address[] investors);

    modifier MoreThanZero(uint256 _number) {
        if (_number <= 0) {
            revert Main__MoreThanZero(_number);
        }
        _;
    }

    modifier ValidAddress(address _address) {
        if (_address == address(0)) {
            revert Main__MustBeValidAddress(_address);
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert Main__OnlyOwner();
        }
        _;
    }

    modifier onlyAuthorizedUpkeeper() {
        if (!authorizedUpkeepers[msg.sender] && msg.sender != owner) {
            revert Main__OnlyAuthorizedUpkeepers();
        }
        _;
    }

    constructor(address router, uint64 subscriptionId, bytes32 donId) FunctionsClient(router) {
        s_subscriptionId = subscriptionId;
        s_donId = donId;
        owner = msg.sender;
        authorizedUpkeepers[msg.sender] = true;
    }

    /*//////////////////////////////////////////////////////////////
                       EXTERNAL_PUBLIC_FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    receive() external payable {
        emit ContractFunded(msg.sender, msg.value);
    }

    function authorizeUpkeeper(address _upkeeper) external onlyOwner ValidAddress(_upkeeper) {
        authorizedUpkeepers[_upkeeper] = true;
        emit UpkeeperAuthorized(_upkeeper);
    }

    function revokeUpkeeper(address _upkeeper) external onlyOwner {
        authorizedUpkeepers[_upkeeper] = false;
        emit UpkeeperRevoked(_upkeeper);
    }

    function chooseRole(UserRole _role) external {
        if (hasChosenRole[msg.sender]) revert Main__RoleAlereadyChosen();
        userRole[msg.sender] = _role;
        hasChosenRole[msg.sender] = true;
    }

    function createInvoice(uint256 _id, address _buyer, uint256 _amount, uint256 _dueDate)
        external
        MoreThanZero(_id)
        MoreThanZero(_amount)
        ValidAddress(_buyer)
    {
        if (IdExists[_id]) revert Main__MustBeUnique();
        if (userRole[msg.sender] != UserRole.Supplier) revert Main__CallerMustBeSupplier();
        if (block.timestamp >= _dueDate) revert Main__DueDateMustBeInFuture(_dueDate, block.timestamp);

        IdExists[_id] = true;
        invoices[_id] = Invoice({
            id: _id,
            supplier: msg.sender,
            buyer: _buyer,
            amount: _amount,
            investors: new address[](0),
            status: InvoiceStatus.Pending,
            dueDate: _dueDate,
            totalInvestment: 0,
            isPaid: false
        });
        buyerInvoices[_buyer].push(_id);
        supplierInvoices[msg.sender].push(_id);
        arrayOfInoviceIds.push(_id);

        emit InvoiceCreated(_id, msg.sender, _buyer, _amount, _dueDate);
    }

    function verifyInvoice(uint256 invoiceId, uint256 amount) external {
        if (userRole[msg.sender] != UserRole.Supplier) revert Main__CallerMustBeSupplier();
        if (invoices[invoiceId].status != InvoiceStatus.Pending) revert Main__InvoiceStatusMustBePending();

        invoices[invoiceId].status = InvoiceStatus.VerificationInProgress;

        // Fixed JavaScript source string with proper concatenation and syntax
        string memory source = "const invoiceId = args[0];" "const amount = Number(args[1]) / 100;"
            "const apiResponse = await Functions.makeHttpRequest({"
            "url: 'https://project-server-seven-ecru.vercel.app'," "method: 'POST'," "headers: {"
            "'Authorization': `Bearer ${secrets.apiKey}`," "'Content-Type': 'application/json'" "}," "data: {"
            "invoiceId: invoiceId," "amount: amount" "}" "});" "if(apiResponse.error){" "throw Error('ERP API failed');"
            "}" "const isValid = apiResponse.data.isValid;" "return Functions.encodeUint256(isValid ? 1 : 0);";

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);

        string[] memory args = new string[](2);
        args[0] = _uint2str(invoiceId);
        args[1] = _uint2str(amount);
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), s_subscriptionId, s_gasLimit, s_donId);

        pendingRequests[requestId] = invoiceId;
        emit InvoiceVerificationRequested(invoiceId, requestId);
    }

    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory error) internal override {
        uint256 invoiceId = pendingRequests[requestId];
        if (invoices[invoiceId].status != InvoiceStatus.VerificationInProgress) {
            revert Main__InvoiceStatusMustBeVerificationInProgress();
        }

        if (error.length > 0) {
            invoices[invoiceId].status = InvoiceStatus.Rejected;
            emit InvoiceVerified(invoiceId, false);
        } else {
            uint256 result = abi.decode(response, (uint256));
            if (result == 1) {
                invoices[invoiceId].status = InvoiceStatus.Approved;
                _generateErc20(invoices[invoiceId].id, invoices[invoiceId].amount);
                emit InvoiceVerified(invoiceId, true);
            } else {
                invoices[invoiceId].status = InvoiceStatus.Rejected;
                emit InvoiceVerified(invoiceId, false);
            }
        }
        delete pendingRequests[requestId];
    }

    function buyTokens(uint256 _id, uint256 _amount) external payable MoreThanZero(_amount) {
        if (userRole[msg.sender] != UserRole.Investor) revert Main__CallerMustBeInvestor();
        if (invoiceToken[_id] == address(0)) revert Main__InvoiceTokenNotFound();
        if (invoices[_id].status != InvoiceStatus.Approved) revert Main__InvoiceMustBeApproved();

        amountOfTokensPurchasedByInvestor[_id][msg.sender] += _amount;
        invoices[_id].totalInvestment += _amount;
        if (amountOfTokensPurchasedByInvestor[_id][msg.sender] == _amount) {
            invoices[_id].investors.push(msg.sender);
        }
        InvoiceToken token = InvoiceToken(invoiceToken[_id]);
        uint256 tokenPriceInEth = token.getExactCost(_amount);
        bool success = token.buyTokens{value: tokenPriceInEth}(_amount, msg.sender);
        if (!success) revert Main__TokensBuyingFails();
        emit SuccessfulTokenPurchase(_id, msg.sender, _amount);
    }

    function buyerPayment(uint256 _id) external payable {
        if (userRole[msg.sender] != UserRole.Buyer) revert Main__CallerMustBeBuyer();
        if (IdExists[_id] == false) revert Main__InvoiceNotExist();
        if (invoices[_id].buyer != msg.sender) revert Main__MustBeBuyerOfTheInvoice();
        if (invoices[_id].status != InvoiceStatus.Approved) revert Main__InvoiceMustBeApproved();
        if (invoices[_id].status == InvoiceStatus.Paid) revert Main__InvoiceAlreadyPaid();

        InvoiceToken token = InvoiceToken(invoiceToken[_id]);
        uint256 totalDebtAmountInDollars = _getTotalDebtAmount(_id);
        if (totalDebtAmountInDollars >= 2 * invoices[_id].amount) {
            totalDebtAmountInDollars = 2 * invoices[_id].amount;
        }
        uint256 totalDebtAmount = token.getExactCost(totalDebtAmountInDollars);

        if (msg.value < totalDebtAmount) {
            revert Main__InsufficientPayment();
        }
        invoices[_id].status = InvoiceStatus.Paid;

        distributionCounter++;
        pendingDistributions[distributionCounter] =
            PaymentDistribution({invoiceId: _id, totalPayment: msg.value, processed: false, timestamp: block.timestamp});
        totalPendingDistributions++;

        emit PaymentReceived(_id, msg.sender, msg.value);
        emit InvoicePaid(_id, msg.value);
    }

    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (totalPendingDistributions == 0 || nextDistributionToProcess > distributionCounter) {
            return (false, bytes(""));
        }

        uint256[] memory readyDistributions = new uint256[](MAX_PENDING_DISTRIBUTIONS);
        uint256 count = 0;
        uint256 currentId = nextDistributionToProcess;

        while (currentId <= distributionCounter && count < MAX_PENDING_DISTRIBUTIONS) {
            PaymentDistribution memory distribution = pendingDistributions[currentId];

            if (!distribution.processed && distribution.timestamp > 0) {
                readyDistributions[count] = currentId;
                count++;
                upkeepNeeded = true;
            }

            currentId++;
        }

        if (upkeepNeeded && count > 0) {
            uint256[] memory finalDistributions = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                finalDistributions[i] = readyDistributions[i];
            }
            performData = abi.encode(finalDistributions);
        }
    }

    function performUpkeep(bytes calldata performData) external override onlyAuthorizedUpkeeper nonReentrant {
        uint256[] memory distributionIds = abi.decode(performData, (uint256[]));
        uint256 length = distributionIds.length;
        for (uint256 i = 0; i < length;) {
            uint256 distributionId = distributionIds[i];
            if (!pendingDistributions[distributionId].processed) {
                _processPaymentDistribution(distributionId);
                _burnToken(distributionId);

                if (distributionId == nextDistributionToProcess) {
                    _updateNextDistributionPointer();
                }
            }
            unchecked {
                i++;
            }
        }
    }
    /*//////////////////////////////////////////////////////////////
                       INTERNAL_PRIVATE_FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _processPaymentDistribution(uint256 _distributionId) internal {
        PaymentDistribution storage distribution = pendingDistributions[_distributionId];
        uint256 invoiceId = distribution.invoiceId;
        uint256 totalPaymentInEth = distribution.totalPayment;

        Invoice storage invoice = invoices[invoiceId];

        if (invoice.investors.length == 0) {
            _sendPayment(invoice.supplier, totalPaymentInEth);
            emit PaymentToSupplier(invoiceId, invoice.supplier, totalPaymentInEth);
        } else {
            uint256 totalInvestment = invoice.totalInvestment;
            uint256 supplierPaymentInEth = 0;
            uint256 totalInvestorPaymentInEth = 0;

            uint256 investorCount = invoice.investors.length;
            for (uint256 i = 0; i < investorCount;) {
                address investor = invoice.investors[i];
                uint256 investmentAmount = amountOfTokensPurchasedByInvestor[invoiceId][investor];

                if (investmentAmount > 0) {
                    uint256 paymentShareInEth = (totalPaymentInEth * investmentAmount) / totalInvestment;
                    _sendPayment(investor, paymentShareInEth);
                    totalInvestorPaymentInEth += paymentShareInEth;
                    emit PaymentDistributed(invoiceId, investor, paymentShareInEth);
                }
                unchecked {
                    i++;
                }
            }

            supplierPaymentInEth = totalPaymentInEth - totalInvestorPaymentInEth;
            if (supplierPaymentInEth > 0) {
                _sendPayment(invoice.supplier, supplierPaymentInEth);
                emit PaymentToSupplier(invoiceId, invoice.supplier, supplierPaymentInEth);
            }
        }

        distribution.processed = true;
        totalPendingDistributions--;
    }

    function _burnToken(uint256 distributionId) internal {
        uint256 inovideId = pendingDistributions[distributionId].invoiceId;
        Invoice storage invoice = invoices[inovideId];

        if (invoice.investors.length > 0) {
            address tokenAddress = invoiceToken[inovideId];
            if (tokenAddress != address(0)) {
                InvoiceToken token = InvoiceToken(tokenAddress);

                uint256 totalBurned = token.burnAllTokens(invoice.investors);

                if (totalBurned != token.totalSupply()) {
                    revert Main__ErrorInBurningTokens();
                }
            }
        }

        emit AllTokensBurned(inovideId, invoice.investors);
    }

    function _updateNextDistributionPointer() internal {
        while (nextDistributionToProcess <= distributionCounter) {
            if (
                pendingDistributions[nextDistributionToProcess].processed
                    || pendingDistributions[nextDistributionToProcess].timestamp == 0
            ) {
                nextDistributionToProcess++;
            } else {
                break;
            }
        }
    }

    function _sendPayment(address _receiver, uint256 _amount) internal {
        (bool success,) = payable(_receiver).call{value: _amount}("");
        if (!success) revert Main__PaymentDistributionFailed();
    }

    function _generateErc20(uint256 _id, uint256 _amount) internal {
        string memory name = string(abi.encodePacked("InvoiceToken_", _uint2str(_id)));
        string memory symbol = string(abi.encodePacked("IT_", _uint2str(_id)));

        InvoiceToken newInvoiceToken = new InvoiceToken(name, symbol, _amount, invoices[_id].supplier, address(this));

        invoiceToken[_id] = address(newInvoiceToken);
        emit InvoiceTokenCreated(_id, address(newInvoiceToken));
    }

    function _getTotalDebtAmount(uint256 _id) internal view returns (uint256) {
        uint256 debtAmount = invoices[_id].amount;
        uint256 graceDueTime = invoices[_id].dueDate + GRACEPERIOD;

        if (block.timestamp > graceDueTime) {
            uint256 overdueTime = block.timestamp - graceDueTime;
            uint256 penalty = (debtAmount * 4 / 100) * (overdueTime / 1 days);
            return debtAmount + penalty;
        }
        return debtAmount;
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    /*//////////////////////////////////////////////////////////////
                       GETTER_FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getBuyerInvoiceIds(address _buyer) external view returns (uint256[] memory) {
        return buyerInvoices[_buyer];
    }

    function getSupplierInvoices(address _supplier) external view returns (uint256[] memory) {
        return supplierInvoices[_supplier];
    }

    function getInvoice(uint256 _invoiceId) external view returns (Invoice memory) {
        return invoices[_invoiceId];
    }

    function getAllInvoiceIds() external view returns (uint256[] memory) {
        return arrayOfInoviceIds;
    }

    function getInvoiceStatus(uint256 _invoiceId) external view returns (InvoiceStatus) {
        return invoices[_invoiceId].status;
    }

    function isAuthorizedUpkeeper(address _upkeeper) external view returns (bool) {
        return authorizedUpkeepers[_upkeeper];
    }

    function getPriceOfTokenInEth(uint256 _invoiceId) external view returns (uint256) {
        InvoiceToken token = InvoiceToken(invoiceToken[_invoiceId]);
        return token.getExactCost(1e18);
    }

    function getTokenDetails(uint256 _invoiceId)
        external
        view
        returns (
            address tokenAddress,
            string memory name,
            string memory symbol,
            uint256 totalSupply,
            address supplier,
            uint256 remainingCapacity
        )
    {
        InvoiceToken token = InvoiceToken(invoiceToken[_invoiceId]);

        return (
            invoiceToken[_invoiceId],
            token.name(),
            token.symbol(),
            token.totalSupply(),
            token.getSupplier(),
            token.remainingCapacity()
        );
    }

    function getUserRole(address _user) external view returns (UserRole) {
        return userRole[_user];
    }

    function getInvoiceTokenAddress(uint256 _invoiceId) external view returns (address) {
        return invoiceToken[_invoiceId];
    }

    function getInvoiceDetails(uint256 _invoiceId)
        external
        view
        returns (
            uint256 id,
            address supplier,
            address buyer,
            uint256 amount,
            address[] memory investors,
            InvoiceStatus status,
            uint256 dueDate,
            uint256 totalInvestment,
            bool isPaid
        )
    {
        Invoice storage invoice = invoices[_invoiceId];
        return (
            invoice.id,
            invoice.supplier,
            invoice.buyer,
            invoice.amount,
            invoice.investors,
            invoice.status,
            invoice.dueDate,
            invoice.totalInvestment,
            invoice.isPaid
        );
    }

    function getTotalSupply(uint256 _invoiceId) external view returns (uint256) {
        InvoiceToken token = InvoiceToken(invoiceToken[_invoiceId]);
        return token.totalSupply();
    }

    function getMaxSupply(uint256 _invoiceId) external view returns (uint256) {
        InvoiceToken token = InvoiceToken(invoiceToken[_invoiceId]);
        return token.maxSupply();
    }
}
