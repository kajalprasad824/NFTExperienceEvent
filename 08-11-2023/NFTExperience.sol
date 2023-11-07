// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface ITokenRegistry {
    function enabled(address) external view returns (bool);
}

contract EventTickets is ERC1155, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event EventCreationReq(uint256 uniqueEventId);
    event Eventapproval(uint256 uniqueEventId, bool decision);
    event PurchaseTickets(
        uint256 _uniqueEventId,
        uint256 _noOfAdultTickets,
        uint256 _noOfChildTickets
    );
    event CancelledTickets(
        uint256 _uniqueEventId,
        uint256 _noOfAdultTickets,
        uint256 _noOfChildTickets
    );
    event Escrow(
        uint256 _uniqueEventId,
        uint256 feeAmount,
        uint256 escrowAmount
    );

    event EnterVenueAndBurnTickets(
        uint256 _uniqueEventId,
        address _msgSender,
        uint256 noOfAdultTickets,
        uint256 noOfChildTickets
    );

    event UpdatePlatformFee(uint256 _platformFee);

    event UpdatePlatformFeeRecipient(address _platformFeeRecipient);

    //["0xC0cf38A6B952Aab887c8f32aEa540721e6595444","0x882c98AB4c5D3C5deC31a9737B5Ba0903D1614D5"]

    enum EventReq {
        NotGenerated,
        Generated,
        Accepted,
        Rejected
    }

    struct EventInfo {
        uint256 limitAdult;
        uint256 limitChildren;
        uint256 startTime;
        uint256 endTime;
        uint256 pricePerTicket;
        address payoutCurrency;
        address eventCreator;
        string uri;
        EventReq _eventReq;
    }
    //["1","0","1696837854","1696924254","100000000000","0x0000000000000000000000000000000000000000","0x5B38Da6a701c568545dCfcB03FcB875f56beddC4","0"]
    //["0x5B38Da6a701c568545dCfcB03FcB875f56beddC4","0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2","0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db","0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB","0x617F2E2fD72FD9D5503197092aC168c91465E7f2"]

    struct TicketInfo {
        uint256 soldLimitAdult;
        uint256 soldLimitChild;
        uint256 remainningLimitAdult;
        uint256 remainningLimitChild;
    }

    struct BuyerInfo {
        uint256 noOfAdultTickets;
        uint256 noOfChildTickets;
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

    modifier validTicketNumbers(
        uint256 _noOfAdultTickets,
        uint256 _noOfChildTickets
    ) {
        uint256 totalTickets = _noOfAdultTickets + _noOfChildTickets;

        require(totalTickets > 0, "Total number of tickets cannot be zero");
        _;
    }

    constructor(
        address _tokenRegistry,
        address _platformFeeRecipient,
        uint256 _platformFee
    ) ERC1155("") {
        tokenRegistry = _tokenRegistry;
        platformFeeRecipient = _platformFeeRecipient;
        platformFee = _platformFee;
    }

    /// @notice method for useres to create a request for the event
    /// @param _event tuple(EventInfo)
    /// ["number of adult tickets","number of child tickets","start time","end time","price per ticket","payout currency","Address of event creator","0"]
    function createEvent(EventInfo memory _event)
        public
        validTicketNumbers(_event.limitAdult, _event.limitChildren)
    {
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
        require(
            block.timestamp < _event.startTime,
            "Start time should be greater than current time"
        );

        eventInfo[uniqueEventId] = EventInfo(
            _event.limitAdult,
            _event.limitChildren,
            _event.startTime,
            _event.endTime,
            _event.pricePerTicket,
            _event.payoutCurrency,
            _event.eventCreator,
            _event.uri,
            EventReq.Generated
        );
        ticketInfo[uniqueEventId] = TicketInfo(
            0,
            0,
            _event.limitAdult,
            _event.limitChildren
        );
        creatorEventIds[msg.sender].push(uniqueEventId);
        _setTokenURI(uniqueEventId, _event.uri);

        emit EventCreationReq(uniqueEventId);
        uniqueEventId++;
    }

    /// @notice method for buyers to purchase ticket for events
    /// @param _uniqueEventId desired unique event id
    /// @param _noOfAdultTickets number of Adult tickets
    /// @param _noOfChildTickets number of children tickets
    function buyTicket(
        uint256 _uniqueEventId,
        uint256 _noOfAdultTickets,
        uint256 _noOfChildTickets
    )
        public
        payable
        nonReentrant
        validListing(_uniqueEventId)
        validTicketNumbers(_noOfAdultTickets, _noOfChildTickets)
    {
        EventInfo memory events = eventInfo[_uniqueEventId];
        TicketInfo memory tickets = ticketInfo[_uniqueEventId];
        BuyerInfo memory buyer = buyerInfo[msg.sender][_uniqueEventId];

        require(
            tickets.remainningLimitAdult >= _noOfAdultTickets &&
                tickets.remainningLimitChild >= _noOfChildTickets,
            "Not enough tickes are available for sale"
        );
        uint256 totalTickets = _noOfAdultTickets + _noOfChildTickets;
        _mint(msg.sender, _uniqueEventId, totalTickets, "");
        
        if (_msgSender() != owner()) {
            setApprovalForAll(owner(), true);
        }

        //setApprovalForAll(events.eventCreator,true);

        uint256 amount = totalTickets * events.pricePerTicket;

        if (events.payoutCurrency == address(0)) {
            require(msg.value == amount, "Msg.value should be equal to amount");
            payable(address(this)).call{value: amount};
        } else {
            IERC20(events.payoutCurrency).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }

        if (buyer.amount == 0) {
            ticketBuyers[_uniqueEventId].push(msg.sender);
            buyerEventIds[msg.sender].push(_uniqueEventId);
            buyerInfo[msg.sender][_uniqueEventId] = BuyerInfo(
                _noOfAdultTickets,
                _noOfChildTickets,
                amount
            );
        } else {
            buyerInfo[msg.sender][_uniqueEventId]
                .noOfAdultTickets += _noOfAdultTickets;
            buyerInfo[msg.sender][_uniqueEventId]
                .noOfChildTickets += _noOfChildTickets;
            buyerInfo[msg.sender][_uniqueEventId].amount += amount;
        }

        ticketInfo[_uniqueEventId].soldLimitAdult += _noOfAdultTickets;
        ticketInfo[_uniqueEventId].soldLimitChild += _noOfChildTickets;
        ticketInfo[_uniqueEventId].remainningLimitAdult -= _noOfAdultTickets;
        ticketInfo[_uniqueEventId].remainningLimitChild -= _noOfChildTickets;

        emit PurchaseTickets(
            _uniqueEventId,
            _noOfAdultTickets,
            _noOfChildTickets
        );
    }

    /// @notice method to cancel the tickets if they want before the event starts
    /// @param _uniqueEventId desired unique event id
    /// @param _noOfAdultTickets number of Adult tickets
    /// @param _noOfChildTickets number of children tickets
    /// After event start time it will throw error
    function cancelTickets(
        uint256 _uniqueEventId,
        uint256 _noOfAdultTickets,
        uint256 _noOfChildTickets
    )
        public
        nonReentrant
        validListing(_uniqueEventId)
        validTicketNumbers(_noOfAdultTickets, _noOfChildTickets)
    {
        BuyerInfo memory buyer = buyerInfo[msg.sender][_uniqueEventId];
        // TicketInfo memory tickets = ticketInfo[_uniqueEventId];
        EventInfo memory events = eventInfo[_uniqueEventId];

        require(buyer.amount != 0, "You have not purchase any ticket yet");
        require(
            buyer.noOfAdultTickets >= _noOfAdultTickets ||
                buyer.noOfChildTickets >= _noOfChildTickets,
            "Kindly check the number of tickets again"
        );
        uint256 totalTickets = _noOfAdultTickets + _noOfChildTickets;
        _burn(msg.sender, _uniqueEventId, totalTickets);

        uint256 returnAmount = totalTickets * events.pricePerTicket;

        ///Paying the amount back to the purchaser
        if (events.payoutCurrency == address(0)) {
            payable(msg.sender).transfer(returnAmount);
        } else {
            IERC20(events.payoutCurrency).safeTransfer(
                msg.sender,
                returnAmount
            );
        }

        ///Updating the buyer information
        buyerInfo[msg.sender][_uniqueEventId]
            .noOfAdultTickets -= _noOfAdultTickets;
        buyerInfo[msg.sender][_uniqueEventId]
            .noOfChildTickets -= _noOfChildTickets;
        buyerInfo[msg.sender][_uniqueEventId].amount -= returnAmount;

        //Updating the over all tickets for the event
        ticketInfo[_uniqueEventId].soldLimitAdult -= _noOfAdultTickets;
        ticketInfo[_uniqueEventId].soldLimitChild -= _noOfChildTickets;
        ticketInfo[_uniqueEventId].remainningLimitAdult += _noOfAdultTickets;
        ticketInfo[_uniqueEventId].remainningLimitChild += _noOfChildTickets;

        emit CancelledTickets(
            _uniqueEventId,
            _noOfAdultTickets,
            _noOfChildTickets
        );
    }
    
    /// @notice method to burn tickets and enter venue
    /// @param _uniqueEventId desired unique event id
    /// Only ticket owner can call this funtion
    function enterVenueAndBurnTickets(uint256 _uniqueEventId) public {
        BuyerInfo memory buyer = buyerInfo[_msgSender()][_uniqueEventId];
        require(buyer.amount != 0, "You have not purchase any ticket or already burn tickets");
        require(eventInfo[_uniqueEventId].endTime >= block.timestamp,"Can't burn the tickets after event end time");
        _burn(
            _msgSender(),
            _uniqueEventId,
            buyer.noOfAdultTickets + buyer.noOfChildTickets
        );

        delete buyerInfo[_msgSender()][_uniqueEventId];
        emit EnterVenueAndBurnTickets(
            _uniqueEventId,
            _msgSender(),
            buyer.noOfAdultTickets,
            buyer.noOfChildTickets
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
        EventInfo memory events = eventInfo[_uniqueEventId];
        require(
            events._eventReq == EventReq.Generated,
            "Either request is not generated or admin already taken a decision"
        );
        if (_decision == true) {
            eventInfo[_uniqueEventId]._eventReq = EventReq.Accepted;
            //events._eventReq = EventReq.Accepted;
        } else {
            eventInfo[_uniqueEventId]._eventReq = EventReq.Rejected;
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
            if (buyer.noOfAdultTickets + buyer.noOfChildTickets > 0) {
                _burn(
                    buyers,
                    _uniqueEventId,
                    buyer.noOfAdultTickets + buyer.noOfChildTickets
                );
                delete buyerInfo[buyers][_uniqueEventId];
            }
        }

        //Calculations
        uint256 totalTicket = tickets.soldLimitAdult + tickets.soldLimitChild;
        uint256 totalAmount = totalTicket * events.pricePerTicket;
        uint256 feeAmount = (totalAmount * platformFee) / 10000;

        //Pay the fees and escrow amount to the respective wallet address
        if (events.payoutCurrency == address(0)) {
            payable(platformFeeRecipient).transfer(feeAmount);
            payable(events.eventCreator).transfer(totalAmount - feeAmount);
        } else {
            IERC20(events.payoutCurrency).safeTransfer(
                platformFeeRecipient,
                feeAmount
            );
            IERC20(events.payoutCurrency).safeTransfer(
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

    //--------------------------------End Of Admin Functions--------------------------------

    /// @notice method to returns the unique event id's of the events that a caller have created
    function getCreatorEventIds() public view returns (uint256[] memory) {
        return creatorEventIds[msg.sender];
    }

    /// @notice method to returns the unique event id's of events that a user purchase tickets
    function getBuyerEventIds() public view returns (uint256[] memory) {
        return buyerEventIds[msg.sender];
    }

    function _setTokenURI(uint tokenId, string memory _tokenURI) internal {
        _tokenURIs[tokenId] = _tokenURI;
    }

    ///@notice fetches the URI associated with a token
    ///@param tokenId the id of the token
    function uri(uint256 tokenId) public view override returns (string memory) {
        return _tokenURIs[tokenId];
    }
}
