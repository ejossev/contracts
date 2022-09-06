pragma solidity ^0.8.0;
// SPDX-License-Identifier: MIT

import "./sample-nft.sol";
import "../openzeppelin-contracts/contracts/utils/Counters.sol";
import "../openzeppelin-contracts/contracts/access/AccessControlEnumerable.sol";
import "../openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";
import "./upgradeable.sol";

interface INotifyExtraTransfer{
    function allowTransferForUser(uint256 id, address from) external;
}

// Please note, that the memory layout is prepared to use generic NFTs, not only 
// SampleNfts. Although this is not part of the initial implementation, it has been 
// extended to avoid possible future upgrade issues.
abstract contract SampleMarketplaceMemoryLayout is AccessControlEnumerable, SampleUpgradeable {
    struct NftIdentifier {
        address nftContract;
        uint256 nftId;
    }

    struct Offer {
        address owner;
        NftIdentifier nftIdentifier;
        uint256 amount;
        uint256 price;
        // linked list entries
        uint256 next;
        uint256 previous;
    }

    struct OrderBook {
        mapping (uint256 => Offer) offers;
        uint256 bestOffer;
    }

    IERC1155 public nftAddress;
    bool public nftHasAccessControl=false;
    mapping(address => mapping (uint256 => uint256)) public royaltyFees;
    mapping(address => mapping (uint256 => address)) public royaltyFeesReceiver;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_SETTER_ROLE = keccak256("FEE_SETTER_ROLE");

    Counters.Counter uidCounter;

    mapping (address => uint256[]) public ownerOffersMap;
    mapping (uint256 => NftIdentifier) public offerIdMap;
    mapping (address => mapping(uint256 => OrderBook)) public orderBooks;

    uint256 MAX_OFFERS;
    bool reentrancyGuard;

    bytes32 public constant FL_FEE_ADMIN = keccak256("FL_FEE_ADMIN");
    bytes32 public constant EF_FEE_ADMIN = keccak256("EF_FEE_ADMIN");
    //the fee accounts will be probably determined after deployement of the smart contracts, so don't initialize in the main initializer
    bool platformFeesInitialized;
    address flFeeReceiver;
    address efFeeReceiver;

    bytes32 public constant GIFTED_TOKEN_ADMIN = keccak256("GIFTED_TOKEN_ADMIN");
    mapping (address => mapping(uint256 => mapping(address => uint256))) public extraFees;
    mapping (address => mapping(uint256 => mapping(address => uint256))) public floorPrices;
}

contract SampleMarketplace is IERC1155Receiver, ERC165, SampleMarketplaceMemoryLayout  {
    using Counters for Counters.Counter;
    
    event NftSet(address indexed nftAddress);
    event RoyaltyFeeSet(uint256 indexed id, uint256 fee, address receiver);
    event ExtraFeeSet(uint256 indexed id, address indexed owner, uint256 fee, uint256 floorPrice);
    event OfferCreated(address indexed owner, uint256 indexed id, uint256 indexed uid, uint256 price, uint256 amount);
    event OfferMatched(address oldOwner, address indexed buyer, uint256 indexed id, uint256 indexed uid, uint256 paidSeller, uint256 paidFee, uint256 amount);
    event OfferCanceled(address indexed owner, uint256 indexed id, uint256 indexed uid);

    constructor() {
        initialized = true;
    }

    function _initializer(bytes calldata data) internal override {
        (address nftAddress_) = abi.decode(data, (address));
        nftAddress = IERC1155(nftAddress_);
        nftHasAccessControl = _supportsAccessControlInterface(nftAddress_);
        emit NftSet(address(nftAddress));

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_SETTER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(GIFTED_TOKEN_ADMIN, ADMIN_ROLE);
        _setupRole(ADMIN_ROLE, msg.sender);
        
        MAX_OFFERS = 20;
    }

    function initializePlatformFees(address flAdmin, address flReceiver, address efAdmin, address efReceiver) public onlyRole(ADMIN_ROLE) {
        require(!platformFeesInitialized, "already initialized");
        _setRoleAdmin(FL_FEE_ADMIN, FL_FEE_ADMIN);
        _setRoleAdmin(EF_FEE_ADMIN, EF_FEE_ADMIN);
        _setupRole(FL_FEE_ADMIN, flAdmin);
        _setupRole(EF_FEE_ADMIN, efAdmin);
        flFeeReceiver = flReceiver;
        efFeeReceiver = efReceiver;
        platformFeesInitialized = true;
    }

    function updateFlFeeReceiver(address flReceiver) public onlyRole(FL_FEE_ADMIN) {
        flFeeReceiver = flReceiver;
    }

    function updateEfFeeReceiver(address efReceiver) public onlyRole(EF_FEE_ADMIN) {
        efFeeReceiver = efReceiver;
    }

    function setNft(address nftAddress_) public onlyRole(ADMIN_ROLE) {
        nftAddress = IERC1155(nftAddress_);
        nftHasAccessControl = _supportsAccessControlInterface(nftAddress_);
        emit NftSet(address(nftAddress));
    }

    // Fee is set as a parts per million, e.g. 100000 is equal to 10%
    function setRoyaltyFee(address nftContract, uint256 nftId, uint256 fee) public {
        require(fee < (getFeeDenominator() - getPlatformFee()), "Fee is too high");
        if (nftHasAccessControl) {
            bytes32 MINTER_ROLE = keccak256(abi.encodePacked("MINTER_ROLE", nftId));
            require(IAccessControl(address(nftContract)).hasRole(MINTER_ROLE, msg.sender));
        } else {
            require(hasRole(FEE_SETTER_ROLE, msg.sender), "Unauthorized.");
        }
        royaltyFees[nftContract][nftId] = fee;
        royaltyFeesReceiver[nftContract][nftId] = msg.sender;
        emit RoyaltyFeeSet(nftId, fee, msg.sender);
    }

    function setExtraFee(address nftContract, uint256 nftId, address owner, uint256 fee, uint256 floorPrice) public onlyRole(GIFTED_TOKEN_ADMIN) {
        extraFees[nftContract][nftId][owner] = fee;
        floorPrices[nftContract][nftId][owner] = floorPrice;
        emit ExtraFeeSet(nftId, owner, fee, floorPrice);
    }

    function setRoyaltyFeeReceiver(address nftContract, uint256 nftId, address receiver) public {
        if (nftHasAccessControl) {
            bytes32 MINTER_ROLE = keccak256(abi.encodePacked("MINTER_ROLE", nftId));
            require(IAccessControl(address(nftContract)).hasRole(MINTER_ROLE, msg.sender));
            royaltyFeesReceiver[nftContract][nftId] = receiver;
        } else {
            require(hasRole(FEE_SETTER_ROLE, msg.sender), "Unauthorized.");
            royaltyFeesReceiver[nftContract][nftId] = receiver;
        }
        emit RoyaltyFeeSet(nftId, royaltyFees[nftContract][nftId], receiver);
    }

    function _supportsERC165Interface(address account, bytes4 interfaceId) private view returns (bool) {
        bytes memory encodedParams = abi.encodeWithSelector(IERC165.supportsInterface.selector, interfaceId);
        (bool success, bytes memory result) = account.staticcall{gas: 30000}(encodedParams);
        if (result.length < 32) return false;
        return success && abi.decode(result, (bool));
    }

    function _supportsAccessControlInterface(address addr) internal view returns (bool) {
        bytes4 _INTERFACE_ID_INVALID = 0xffffffff;
        bool supportIERC165 = _supportsERC165Interface(addr, type(IERC165).interfaceId) &&
            !_supportsERC165Interface(addr, _INTERFACE_ID_INVALID);
        if (!supportIERC165)
            return false;
        return _supportsERC165Interface(addr, type(IAccessControl).interfaceId);
    }

    function _calculateFee(address owner, address nftContract, uint256 nftId, uint256 value) internal view returns (uint256 forOwner, uint256 fee, uint256 platformFee) {
        fee = 0;
        forOwner = 0;
        platformFee = 0;

        if (platformFeesInitialized) {
            platformFee = value * getPlatformFee() / getFeeDenominator();
        }

        uint256 maxFee = value - platformFee;
        
        if (royaltyFees[nftContract][nftId] + extraFees[nftContract][nftId][owner] != 0 && 
            royaltyFeesReceiver[nftContract][nftId] != address(0) && 
            royaltyFeesReceiver[nftContract][nftId] != owner) 
        {
            fee = value * (royaltyFees[nftContract][nftId] + extraFees[nftContract][nftId][owner]) / getFeeDenominator();
        }

        if (fee > maxFee)
            fee = maxFee;

        forOwner = value - fee - platformFee;
    }

    function getTotalFee(address owner, address nftContract, uint256 nftId) public view returns (uint256 fee) {
        fee = 0;
        if (platformFeesInitialized)
            fee += getPlatformFee();
        if (royaltyFees[nftContract][nftId] + extraFees[nftContract][nftId][owner] != 0 && 
            royaltyFeesReceiver[nftContract][nftId] != address(0) && 
            royaltyFeesReceiver[nftContract][nftId] != owner) 
        {
            fee += royaltyFees[nftContract][nftId] + extraFees[nftContract][nftId][owner];
        }

        if (fee > getFeeDenominator() - getPlatformFee())
            fee = getFeeDenominator() - getPlatformFee();
    }

    function getFeeDenominator() pure public returns (uint256) {
        return 10000;
    }

    function getPlatformFee() pure public returns (uint256) {
        return 250;
    }

    function _getUid() internal returns (uint256) {
        uidCounter.increment();
        return uidCounter.current();
    }

    function _deleteFromArray(uint256[] storage array, uint256 uid) internal {
        for (uint256 i=0; i < array.length; i++) {
            if (array[i] == uid) {
                if (array.length > 1)
                    array[i] = array[array.length - 1];
                array.pop();
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC165, AccessControlEnumerable) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    function onERC1155Received(address , address from, uint256 id, uint256 value, bytes calldata data) public virtual override returns (bytes4) {
        (uint256 price, uint256 putBehind) = abi.decode(data, (uint256, uint256));
        require(address(nftAddress) == msg.sender, "Accepting offers only for Sample tokens");
        require(price >= floorPrices[msg.sender][id][from] && price > 0, "Wrong price");
        uint256 uid = _createOffer(from, msg.sender, id, price, value, putBehind);
        emit OfferCreated(from, id, uid, price, value);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) public virtual override returns (bytes4) {
        require(false, "not implemented");
        return this.onERC1155BatchReceived.selector;
    }

    function acceptOffer(uint256 uid, uint256 amount) public payable {
        require(!reentrancyGuard);
        reentrancyGuard = true;
        NftIdentifier memory id = offerIdMap[uid];

        Offer memory offer = orderBooks[id.nftContract][id.nftId].offers[uid];
        address owner = offer.owner;
        require(owner != address(0), "Offer does not exist");
        require(offer.amount >= amount, "not enough tokens to fill request");
        require(offer.price * amount <= msg.value, "Please pay the full price");
        
        _updateOffer(uid, id.nftContract, id.nftId, offer.amount - amount);

        IERC1155(offer.nftIdentifier.nftContract).safeTransferFrom(address(this), msg.sender, id.nftId, amount, "");
        (uint256 forOwner, uint256 fee, uint256 platformFee) = _calculateFee(owner, id.nftContract, id.nftId, msg.value);

        (bool success, ) = owner.call{value: forOwner}("");
        // If recipient cannot receive the payment, pay everything to the fee receiver
        if (!success)
            fee = msg.value;

        if (fee > 0) {
            require(royaltyFeesReceiver[id.nftContract][id.nftId] != address(0), "Contact the minter to set proper fee receiver!");
            (bool success2, ) = royaltyFeesReceiver[id.nftContract][id.nftId].call{value: fee}("");
            require(success2, "Contact the minter to set proper fee receiver!");
        }

        if (platformFee > 0) {
            require(flFeeReceiver != address(0) && efFeeReceiver != address(0));
            uint256 halbFee = platformFee / 2;
            // Do not check the return values of these 2 calls, as we don't want to stop processing in either case
            (bool success3, ) = efFeeReceiver.call{value: halbFee}("");
            (bool success4, ) = flFeeReceiver.call{value: platformFee - halbFee}("");
            success3; success4;
        }

        if (extraFees[id.nftContract][id.nftId][owner] > 0 || floorPrices[id.nftContract][id.nftId][owner] > 0) {
            extraFees[id.nftContract][id.nftId][owner] = 0;
            floorPrices[id.nftContract][id.nftId][owner] = 0;
            // try to disable graylist here. not interested in the result though.
            (bool success5, ) = id.nftContract.call(abi.encodeWithSignature("allowTransferForUser(uint256,address)", id.nftId, owner));
            success5;
        }

        emit OfferMatched(owner, msg.sender, id.nftId, uid, forOwner, fee, amount);
        reentrancyGuard = false;
    }

    function _createOffer(address owner, address nftContract, uint256 nftId, uint256 price, uint256 amount, uint256 putBehind) internal returns (uint256 uid) {
        uid = _getUid();

        require(ownerOffersMap[owner].length < MAX_OFFERS, "User reached offer limit");
        ownerOffersMap[owner].push(uid);
        offerIdMap[uid].nftContract = nftContract;
        offerIdMap[uid].nftId = nftId;

        Offer storage newOffer = orderBooks[nftContract][nftId].offers[uid];
        newOffer.owner = owner;
        newOffer.nftIdentifier.nftId = nftId;
        newOffer.nftIdentifier.nftContract = nftContract;
        newOffer.price = price;
        newOffer.amount = amount;

        if (orderBooks[nftContract][nftId].bestOffer == 0) {
            orderBooks[nftContract][nftId].bestOffer = uid;
            return uid;
        }

        if (putBehind == 0) {
            uint256 currentBest = orderBooks[nftContract][nftId].bestOffer;
            require(orderBooks[nftContract][nftId].offers[currentBest].price > price, "Offers must be ordered by price");
            orderBooks[nftContract][nftId].offers[currentBest].previous = uid;
            newOffer.next = currentBest;
            orderBooks[nftContract][nftId].bestOffer = uid;
            return uid;
        }

        require(orderBooks[nftContract][nftId].offers[putBehind].price <= price, "Offers must be ordered by price");
        uint256 next = orderBooks[nftContract][nftId].offers[putBehind].next;
        orderBooks[nftContract][nftId].offers[putBehind].next = uid;
        if (next != 0) {
            require(orderBooks[nftContract][nftId].offers[next].price > price, "Offers must be ordered by price");
            orderBooks[nftContract][nftId].offers[next].previous = uid;
        }
        newOffer.previous = putBehind;
        newOffer.next = next;

        return uid;
    }

    function _deleteOffer(uint256 uid) internal {
        NftIdentifier memory id = offerIdMap[uid];
        Offer storage deletedOffer = orderBooks[id.nftContract][id.nftId].offers[uid];

        _deleteFromArray(ownerOffersMap[deletedOffer.owner], uid);

        if (uid == orderBooks[id.nftContract][id.nftId].bestOffer)
            orderBooks[id.nftContract][id.nftId].bestOffer = deletedOffer.next;
        uint256 previous = deletedOffer.previous;
        uint256 next = deletedOffer.next;

        if (previous != 0)
            orderBooks[id.nftContract][id.nftId].offers[previous].next = next;

        if (next != 0)
            orderBooks[id.nftContract][id.nftId].offers[next].previous = previous;
        
        offerIdMap[uid].nftContract = address(0);
        offerIdMap[uid].nftId = 0;
        deletedOffer.owner = address(0);
        deletedOffer.amount = 0;
        deletedOffer.price = 0;
        deletedOffer.next = 0;
        deletedOffer.previous = 0;
    }

    function _updateOffer(uint256 uid, address nftContract, uint256 nftId, uint256 newAmount) internal {
        if (newAmount == 0)
            _deleteOffer(uid);
        else
            orderBooks[nftContract][nftId].offers[uid].amount = newAmount;
    }

    function findPutBehindOffer(uint256 nftId, uint256 price) public view returns (uint256) {
        require(price > 0);
        OrderBook storage orderBook = orderBooks[address(nftAddress)][nftId];
        uint256 bestOffer = orderBook.bestOffer;
        if (bestOffer == 0)
            return 0;
        
        if (orderBook.offers[bestOffer].price > price)
            return 0;

        uint256 it_ptr = bestOffer;
        uint256 next = orderBook.offers[it_ptr].next;
        while (next != 0 && orderBook.offers[next].price <= price ) {
            it_ptr = next;
            next = orderBook.offers[it_ptr].next;
        }

        return it_ptr;
    }

    function getBestOffers(uint256 nftId, uint256 count) public view returns (address[] memory owners, uint256[] memory uids, uint256[] memory prices, uint256[] memory amounts) {
        owners = new address[](count);
        uids = new uint256[](count);
        prices = new uint256[](count);
        amounts = new uint256[](count);

        uint256 i = 0;
        OrderBook storage orderBook = orderBooks[address(nftAddress)][nftId];
        uint256 bestOffer = orderBook.bestOffer;

        uint256 it_ptr = bestOffer;
        while (it_ptr !=0 && i < count) {
            Offer storage it = orderBook.offers[it_ptr];
            owners[i] = it.owner;
            uids[i] = it_ptr;
            prices[i] = it.price;
            amounts[i] = it.amount;

            it_ptr = orderBook.offers[it_ptr].next;
            i += 1;
        }
    }

    function getBestOfferBatch(uint256[] memory ids) public view returns (uint256[] memory prices) {
        prices = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 nftId = ids[i];
            uint256 uid = orderBooks[address(nftAddress)][nftId].bestOffer;
            prices[i] = orderBooks[address(nftAddress)][nftId].offers[uid].price;
        }
    }

    function getOffer(uint256 uid) public view returns (address nftContract, uint256 nftId, address owner, uint256 price, uint256 amount) {
        NftIdentifier storage id = offerIdMap[uid];
        Offer storage offer = orderBooks[id.nftContract][id.nftId].offers[uid];
        nftContract = id.nftContract;
        nftId = id.nftId;

        require(offer.owner != address(0) , "Offer does not exist");
        owner = offer.owner;
        price = offer.price;
        amount = offer.amount;
    }

    function getUserOffers(address user) public view returns (uint256[] memory ids, uint256[] memory uids, uint256[] memory prices, uint256[] memory amounts) {
        uint256 count = ownerOffersMap[user].length;
        ids = new uint256[](count);
        uids = new uint256[](count);
        prices = new uint256[](count);
        amounts = new uint256[](count);

        for (uint256 i=0; i<count; i++) {
            uint256 uid = ownerOffersMap[user][i];
            NftIdentifier storage id = offerIdMap[uid];
            Offer storage offer = orderBooks[id.nftContract][id.nftId].offers[uid];

            ids[i] = id.nftId;
            uids[i] = uid;
            prices[i] = offer.price;
            amounts[i] = offer.amount;
        }
    }

    function cancelOffer(uint256 uid) public {
        NftIdentifier memory id = offerIdMap[uid];
        address owner = msg.sender;
        require(orderBooks[id.nftContract][id.nftId].offers[uid].owner == owner, "Only owner can delete their offers");
        uint256 amount = orderBooks[id.nftContract][id.nftId].offers[uid].amount;
        _deleteOffer(uid);
        IERC1155(id.nftContract).safeTransferFrom(address(this), owner, id.nftId, amount, "");
        emit OfferCanceled(owner, id.nftId, uid);
    }


}
