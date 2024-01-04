// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITokenRegistry {
    function enabled(address) external view returns (bool);
}

contract EventTickets is ERC1155, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    event EventCreationReq(uint256 uniqueEventId);
    event Eventapproval(uint256 uniqueEventId, bool decision);
    event PurchaseTickets(uint256 _uniqueEventId, uint256 _noOfTickets);
    event CancelledTickets(uint256 _uniqueEventId, uint256 _noOfTickets);
    event Escrow(
        uint256 _uniqueEventId,
        uint256 feeAmount,
        uint256 escrowAmount
    );

    event EnterVenueAndBurnTickets(
        uint256 _uniqueEventId,
        address _msgSender,
        uint256 noOfTickets
    );

    event UpdatePlatformFee(uint256 _platformFee);

    event UpdatePlatformFeeRecipient(address _platformFeeRecipient);

    enum EventReq {
        NotGenerated,
        Generated,
        Accepted,
        Rejected
    }

    struct EventInfo {
        uint256 totalTickets;
        uint256 startTime;
        uint256 endTime;
        uint256 pricePerTicket;
        address payoutCurrency;
        address eventCreator;
        string uri;
        EventReq _eventReq;
    }

    struct TicketInfo {
        uint256 soldTickets;
        uint256 remainningTickets;
    }

    struct BuyerInfo {
        uint256 noOfTickets;
        uint256 amount;
    }

    //unique event id => event info
    mapping(uint256 => EventInfo) public eventInfo;
    //uinique event id => ticket info
    mapping(uint256 => TicketInfo) public ticketInfo;
    //event creators => event id's
    mapping(address => uint256[]) creatorEventIds;
    //buyer => eventId => buyerInfo
    mapping(address => mapping(uint256 => BuyerInfo)) public buyerInfo;
    //buyer => event id's
    mapping(address => uint256[]) buyerEventIds;
    //event id's => buyers
    mapping(uint256 => address[]) ticketBuyers;
    mapping(uint256 => string) private _tokenURIs;

    uint256 uniqueEventId = 1;
    uint256 public platformFee;
    address public platformFeeRecipient;
    address public tokenRegistry;

    modifier validListing(uint256 _uniqueEventId) {
        EventInfo memory events = eventInfo[_uniqueEventId];
        require(
            events._eventReq != EventReq.NotGenerated,
            "No such unique event id exists"
        );
        require(
            events._eventReq != EventReq.Rejected,
            "This unique event id is rejected by the admin"
        );
        require(
            events._eventReq == EventReq.Accepted,
            "This unique event id is still not accepted by admin"
        );

        require(
            events.startTime >= block.timestamp,
            "Only buy and cancel tickets before events start"
        );
        _;
    }

    modifier completedListing(uint256 _uniqueEventId) {
        EventInfo memory events = eventInfo[_uniqueEventId];

        require(
            events._eventReq == EventReq.Accepted,
            "No such unique event id is accepted by admin"
        );

        require(
            events.endTime <= block.timestamp,
            "Only call this function after the end time of event"
        );
        _;
    }

    modifier timeCheck(uint _startTime,uint _endTime) {
        require(
            _startTime > block.timestamp &&
                _startTime < _endTime,
            "Check Time Correctly"
        );
        _;
    }

    constructor(
        address initialOwner,
        address _tokenRegistry,
        address _platformFeeRecipient,
        uint256 _platformFee
    ) Ownable(initialOwner) ERC1155("") {
        tokenRegistry = _tokenRegistry;
        platformFeeRecipient = _platformFeeRecipient;
        platformFee = _platformFee;
    }

    /// @notice method for useres to create a request for the event
    /// @param _event tuple(EventInfo)
    /// ["number of total tickets","start time","end time","price per ticket","payout currency","Address of event creator","0"]
    function createEvent(EventInfo memory _event) public {
        require(_event.totalTickets != 0, "No. of Tickets cannot be zero");

        require(
            _event.startTime > block.timestamp &&
                _event.startTime < _event.endTime,
            "Check Time Correctly"
        );
        require(
            _event.payoutCurrency == address(0) ||
                (tokenRegistry != address(0) &&
                    ITokenRegistry(tokenRegistry).enabled(
                        _event.payoutCurrency
                    )),
            "invalid pay token"
        );

        eventInfo[uniqueEventId] = EventInfo(
            _event.totalTickets,
            _event.startTime,
            _event.endTime,
            _event.pricePerTicket,
            _event.payoutCurrency,
            _event.eventCreator,
            _event.uri,
            EventReq.Generated
        );
        ticketInfo[uniqueEventId] = TicketInfo(0, _event.totalTickets);
        creatorEventIds[msg.sender].push(uniqueEventId);
        _setTokenURI(uniqueEventId, _event.uri);

        emit EventCreationReq(uniqueEventId);
        uniqueEventId++;
    }

    function updateTimeOfEvent(uint _uniqueEventId, uint _startTime,uint _endTime) public{
        EventInfo storage events = eventInfo[_uniqueEventId];

       require (events.eventCreator == _msgSender(),"Only event creator can call this");
       require(
            events._eventReq != EventReq.Accepted,
            " event is already accepted by admin"
        );

        events.startTime = _startTime;
        events.endTime = _endTime;

    }

    /// @notice method for buyers to purchase ticket for events
    /// @param _uniqueEventId desired unique event id
    /// @param _noOfTickets number of Adult tickets
    function buyTicket(uint256 _uniqueEventId, uint256 _noOfTickets)
        public
        payable
        nonReentrant
        validListing(_uniqueEventId)
    {
        address buyer = _msgSender();
        EventInfo memory events = eventInfo[_uniqueEventId];
        TicketInfo storage tickets = ticketInfo[_uniqueEventId];
        BuyerInfo storage buyers = buyerInfo[buyer][_uniqueEventId];

        require(_noOfTickets != 0, "No. of tickets cannot be zero");

        require(
            tickets.remainningTickets >= _noOfTickets,
            "Not enough tickes are available for sale"
        );

        _mint(buyer, _uniqueEventId, _noOfTickets, "");

        if (buyer != owner()) {
            setApprovalForAll(owner(), true);
        }

        uint256 amount = _noOfTickets * events.pricePerTicket;

        if (events.payoutCurrency == address(0)) {
            require(msg.value == amount, "Msg.value should be equal to amount");
            payable(address(this)).call{value: amount};
        } else {
            IERC20(events.payoutCurrency).safeTransferFrom(
                buyer,
                address(this),
                amount
            );
        }

        if (buyers.amount == 0) {
            ticketBuyers[_uniqueEventId].push(buyer);
            buyerEventIds[buyer].push(_uniqueEventId);
            buyerInfo[buyer][_uniqueEventId] = BuyerInfo(_noOfTickets, amount);
        } else {
            buyers.noOfTickets += _noOfTickets;
            buyers.amount += amount;
        }

        tickets.soldTickets += _noOfTickets;
        tickets.remainningTickets -= _noOfTickets;

        emit PurchaseTickets(_uniqueEventId, _noOfTickets);
    }

    /// @notice method to cancel the tickets if they want before the event starts
    /// @param _uniqueEventId desired unique event id
    /// @param _noOfAdultTickets number of Adult tickets

    /// After event start time it will throw error
    function cancelTickets(uint256 _uniqueEventId, uint256 _noOfTickets)
        public
        nonReentrant
        validListing(_uniqueEventId)
    {
        address buyer = _msgSender();
        BuyerInfo storage buyers = buyerInfo[buyer][_uniqueEventId];
        TicketInfo storage tickets = ticketInfo[_uniqueEventId];
        EventInfo memory events = eventInfo[_uniqueEventId];

        require(buyers.amount != 0, "You have not purchase any ticket yet");
        require(
            buyers.noOfTickets >= _noOfTickets,
            "Kindly check the number of tickets again"
        );

        _burn(buyer, _uniqueEventId, _noOfTickets);

        uint256 returnAmount = _noOfTickets * events.pricePerTicket;

        ///Paying the amount back to the purchaser
        if (events.payoutCurrency == address(0)) {
            payable(buyer).transfer(returnAmount);
        } else {
            IERC20(events.payoutCurrency).safeTransfer(buyer, returnAmount);
        }

        ///Updating the buyer information
        buyers.noOfTickets -= _noOfTickets;
        buyers.amount -= returnAmount;

        //Updating the over all tickets for the event
        tickets.soldTickets -= _noOfTickets;
        tickets.remainningTickets += _noOfTickets;

        emit CancelledTickets(_uniqueEventId, _noOfTickets);
    }

    /// @notice method to burn tickets and enter venue
    /// @param _uniqueEventId desired unique event id
    /// Only ticket owner can call this funtion
    function enterVenueAndBurnTickets(uint256 _uniqueEventId) public {
        BuyerInfo memory buyer = buyerInfo[_msgSender()][_uniqueEventId];
        require(
            buyer.amount != 0,
            "You have not purchase any ticket or already burn tickets"
        );
        require(
            eventInfo[_uniqueEventId].endTime >= block.timestamp,
            "Can't burn the tickets after event end time"
        );
        _burn(_msgSender(), _uniqueEventId, buyer.noOfTickets);

        delete buyerInfo[_msgSender()][_uniqueEventId];
        emit EnterVenueAndBurnTickets(
            _uniqueEventId,
            _msgSender(),
            buyer.noOfTickets
        );
    }

    //-------------------------------------Admin Functions---------------------------------

    /// @notice method to update the platform fee percentage
    /// @param _platformFee platform fee percentage
    function updatePlatformFee(uint256 _platformFee) public onlyOwner {
        platformFee = _platformFee;
        emit UpdatePlatformFee(_platformFee);
    }

    /// @notice method to update the platform fee recipient address
    /// @param _platformFeeRecipient platform fee recipient address
    function updatePlatformFeeRecipient(address _platformFeeRecipient)
        public
        onlyOwner
    {
        platformFeeRecipient = _platformFeeRecipient;
        emit UpdatePlatformFeeRecipient(_platformFeeRecipient);
    }

    /// @notice method to take decision whether admin wan to approve the event or not
    /// @param _uniqueEventId desired unique event id
    /// @param _decision decision (true or false)
    function eventApproval(uint256 _uniqueEventId, bool _decision)
        public
        onlyOwner
    {
        EventInfo storage events = eventInfo[_uniqueEventId];
        require(
            events._eventReq == EventReq.Generated,
            "Either request is not generated or admin already taken a decision"
        );
        if (_decision == true) {
            eventInfo[_uniqueEventId]._eventReq = EventReq.Accepted;
            //events._eventReq = EventReq.Accepted;
        } else {
            events._eventReq = EventReq.Rejected;
            delete eventInfo[_uniqueEventId];
            delete ticketInfo[_uniqueEventId];
            //events._eventReq = EventReq.Rejected;
        }

        emit Eventapproval(_uniqueEventId, _decision);
    }

    /// @notice method to call to burn tickets and escrow the amount to event creator
    /// @param _uniqueEventId desired unique event id
    function burnTicketsAndEscrow(uint256 _uniqueEventId)
        public
        nonReentrant
        onlyOwner
        completedListing(_uniqueEventId)
    {
        EventInfo memory events = eventInfo[_uniqueEventId];
        TicketInfo memory tickets = ticketInfo[_uniqueEventId];

        //Burning Tickets for this unique event id
        for (uint256 i = 0; i < ticketBuyers[_uniqueEventId].length; i++) {
            address buyers = ticketBuyers[_uniqueEventId][i];
            BuyerInfo memory buyer = buyerInfo[buyers][_uniqueEventId];
            if (buyer.noOfTickets > 0) {
                _burn(buyers, _uniqueEventId, buyer.noOfTickets);
                delete buyerInfo[buyers][_uniqueEventId];
            }
        }

        //Calculations
        uint256 totalAmount = tickets.soldTickets * events.pricePerTicket;
        uint256 feeAmount = (totalAmount * platformFee) / 10000;

        //Pay the fees and escrow amount to the respective wallet address
        if (events.payoutCurrency == address(0)) {
            payable(platformFeeRecipient).transfer(feeAmount);
            payable(events.eventCreator).transfer(totalAmount - feeAmount);
        } else {
            IERC20(events.payoutCurrency).safeTransferFrom(
                address(this),
                platformFeeRecipient,
                feeAmount
            );
            IERC20(events.payoutCurrency).safeTransferFrom(
                address(this),
                events.eventCreator,
                totalAmount - feeAmount
            );
        }

        //delete all the information related to events
        delete eventInfo[_uniqueEventId];
        delete ticketInfo[_uniqueEventId];
        delete ticketBuyers[_uniqueEventId];

        emit Escrow(_uniqueEventId, feeAmount, totalAmount - feeAmount);
    }

    function burnTicketsandRefund(uint256 _uniqueEventId) public onlyOwner {
        EventInfo memory events = eventInfo[_uniqueEventId];

        require(events.endTime <= block.timestamp, "Wait for end time");

        for (uint256 i = 0; i < ticketBuyers[_uniqueEventId].length; i++) {
            address buyers = ticketBuyers[_uniqueEventId][i];
            BuyerInfo memory buyer = buyerInfo[buyers][_uniqueEventId];
            if (buyer.noOfTickets > 0) {
                _burn(buyers, _uniqueEventId, buyer.noOfTickets);

                if (events.payoutCurrency == address(0)) {
                    payable(buyers).transfer(buyer.amount);
                } else {
                    IERC20(events.payoutCurrency).safeTransfer(
                        buyers,
                        buyer.amount
                    );
                }
            }

            delete buyerInfo[buyers][_uniqueEventId];
        }
        
        delete eventInfo[_uniqueEventId];
        delete ticketInfo[_uniqueEventId];
        delete ticketBuyers[_uniqueEventId];


    }

    //--------------------------------End Of Admin Functions--------------------------------

    /// @notice method to returns the unique event id's of the events that a caller have created
    function getCreatorEventIds() public view returns (uint256[] memory) {
        return creatorEventIds[msg.sender];
    }

    /// @notice method to returns the unique event id's of events that a user purchase tickets
    function getBuyerEventIds() public view returns (uint256[] memory) {
        return buyerEventIds[msg.sender];
    }

    function _setTokenURI(uint256 tokenId, string memory _tokenURI) internal {
        _tokenURIs[tokenId] = _tokenURI;
    }

    ///@notice fetches the URI associated with a token
    ///@param tokenId the id of the token
    function uri(uint256 tokenId) public view override returns (string memory) {
        return _tokenURIs[tokenId];
    }
}
