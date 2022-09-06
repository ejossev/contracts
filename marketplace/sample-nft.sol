// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "../openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import "../openzeppelin-contracts/contracts/access/AccessControlEnumerable.sol";
import "../openzeppelin-contracts/contracts//utils/Strings.sol";
import "./upgradeable.sol";

struct Token {
    uint256 id;
    string name;
    uint256 supply;
    bool created;
    string uri;
}

struct GraylistEntry {
    bool graylisted;
    address[] allowTransferTo; //as the number of entries is expected to be very low (<=2), using array here is appropriate
}

interface INotifyOwnerChange {
    function changeOwner(address nft_address, uint256 nft_id, address newOwner) external;
}

abstract contract SampleTokenMemoryLayout is ERC1155, AccessControlEnumerable, SampleUpgradeable {
    // TransferBlacklistToken part
    mapping(uint256=>bool) public transferBlacklist;
    //ClaimableToken part
    bool public canClaim = false;
    mapping(address=>mapping(uint256=>uint256)) claimable; // claimerAdress => tokenId => allowedToClaim

    //SampleToken part
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TOKEN_PROPOSER_ROLE = keccak256("TOKEN_PROPOSER_ROLE");

    mapping(uint256 => Token) public tokens;
    uint256[] public tokenIds;
    mapping(uint256=>address) public proposedTokens;
    address didRegistry;

    string public baseURI;

    bytes32 public constant CONTRACT_METADATA = keccak256("CONTRACT_METADATA");

    // These tokens can be transfered to marketplace only
    bytes32 public constant GIFTED_TOKEN_ADMIN = keccak256("GIFTED_TOKEN_ADMIN");
    mapping (uint256=>mapping(address=>GraylistEntry)) transferGraylist;


    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControlEnumerable) virtual returns (bool) {
        return
            interfaceId == type(IERC1155).interfaceId ||
            interfaceId == type(IERC1155MetadataURI).interfaceId ||
            interfaceId == type(IAccessControlEnumerable).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}

abstract contract TransferBlacklistToken is SampleTokenMemoryLayout {
    event TransferBlacklisted(uint256 indexed tokenId, bool blacklisted);
    event TransferGraylisted(uint256 indexed tokenId, bool graylisted, address indexed owner);

    function _setTransferBlacklist(uint256 id, bool blacklisted) internal {
        transferBlacklist[id] = blacklisted;
        emit TransferBlacklisted(id, blacklisted);
    }

    function transferAllowed(uint256 id, address from, address to) public view returns (bool) {
        if (transferBlacklist[id])
            return false;
       return graylistTransferAllowed(id, from, to);
    }

    function graylistTransferAllowed(uint256 id, address from, address to) public view returns (bool) {
        if (!transferGraylist[id][from].graylisted)
            return true;
        for (uint i = 0; i < transferGraylist[id][from].allowTransferTo.length; i++) {
            if (transferGraylist[id][from].allowTransferTo[i] == to)
                return true;
        }
        return false;
    }

    function isGraylisted(uint256 id, address owner) public view returns (bool) {
        return transferGraylist[id][owner].graylisted;
    }

    function _setTransferGraylist(uint256 id, address owner, bool graylisted) internal {
        transferGraylist[id][owner].graylisted = graylisted;
        delete transferGraylist[id][owner].allowTransferTo;
        emit TransferGraylisted(id, graylisted, owner);
    }

    function _addTransferGraylistAllowedDestination(uint256 id, address owner, address allowTo) internal {
        transferGraylist[id][owner].allowTransferTo.push(allowTo);
    }
}

abstract contract ClaimableToken is SampleTokenMemoryLayout {
    event Claimed(address indexed user, uint256 indexed tokenId, uint256 amount);

    function claimToken(uint256 tokenId, uint256 amount) virtual public {
        address sender = _msgSender();

        require(canClaim, "Claim is not allowed");
        require(claimable[sender][tokenId] >= amount, "You're not in the whitelist");

        claimable[sender][tokenId] -= amount;
        _mint(sender, tokenId, amount,  "");

        emit Claimed(sender, tokenId, amount); 
    }

    function _whitelistForClaim(address[] memory addresses, uint256[] memory values, uint256 tokenId) internal {
        for (uint256 i = 0; i < addresses.length; i++) {
            claimable[addresses[i]][tokenId] = values[i];
        }
    }
}

contract SampleTokens is SampleTokenMemoryLayout, ClaimableToken, TransferBlacklistToken {
    
    event TokenAdded(uint256 id, string name, address minter);
    event TokenProposed(uint256 id, address minter);
    event ProposalCanceled(uint256 id);

    constructor() ERC1155("https://ipfs.moralis.io:2053/ipfs/QmZzpJnFkZs4QqU73EpR2VG48ZoTpfUnsPyJCTNPDgQ4tV/metadata/{id}.json") {
        initialized = true;
    }

    function _initializer(bytes calldata data) internal override {
        (address didRegistryAddress) = abi.decode(data, (address));
        didRegistry = didRegistryAddress;

        canClaim = false;
        baseURI = "https://ipfs.moralis.io:2053/ipfs/QmZzpJnFkZs4QqU73EpR2VG48ZoTpfUnsPyJCTNPDgQ4tV/metadata/";
        _setRoleAdmin(TOKEN_PROPOSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(GIFTED_TOKEN_ADMIN, ADMIN_ROLE);
        _setupRole(ADMIN_ROLE, msg.sender);

        addToken(uint256(CONTRACT_METADATA), "CONTRACT_METADATA", msg.sender);
        _setTransferBlacklist(uint256(CONTRACT_METADATA), true);
        _mint(msg.sender, uint256(CONTRACT_METADATA), 1, "");
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view override(SampleTokenMemoryLayout) returns (bool) {
        return
            interfaceId == type(IERC1155).interfaceId ||
            interfaceId == type(IERC1155MetadataURI).interfaceId ||
            interfaceId == type(IAccessControlEnumerable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function name() external pure returns (string memory) {
        return "Sample Marketplace";
    }

    function uri(uint256 id) override public view returns (string memory) {
        return tokens[id].uri;
    }

    function setUri(string memory newUri, uint256 id) public {
        bytes32 MINTER_ROLE = keccak256(abi.encodePacked("MINTER_ROLE", id));
        require(hasRole(ADMIN_ROLE, _msgSender()) || hasRole(MINTER_ROLE, _msgSender()), "you cannot set this uri");
        tokens[id].uri = newUri;
        emit URI(newUri, id);
    }

    function setDidRegistry(address newRegistry) public onlyRole(ADMIN_ROLE) {
        didRegistry = newRegistry;
    }

    function allowTransfer(uint256 id) public onlyRole(ADMIN_ROLE) {
        _setTransferBlacklist(id, false);
    }

    function stopTransfer(uint256 id) public onlyRole(ADMIN_ROLE) {
        _setTransferBlacklist(id, true);
    }

    function allowTransferForUser(uint256 id, address from) public {
        require(hasRole(GIFTED_TOKEN_ADMIN, msg.sender) || graylistTransferAllowed(id, from, msg.sender), "You cannot cancel the graylist");
        _setTransferGraylist(id, from, false);
    }

    function graylistTransferForUser(uint256 id, address from) public onlyRole(GIFTED_TOKEN_ADMIN) {
        _setTransferGraylist(id, from, true);
    }

    function addGraylistAllowedDestination(uint256 id, address owner, address allowTo) public onlyRole(GIFTED_TOKEN_ADMIN) {
        _addTransferGraylistAllowedDestination(id, owner, allowTo);
    }

    function allowClaim() public onlyRole(ADMIN_ROLE) {
        canClaim = true;
    }

    function stopClaim() public onlyRole(ADMIN_ROLE) {
        canClaim = false;
    }

    function mintToken(address account, uint256 id, uint256 amount, bytes memory data)
        public
        onlyRole(keccak256(abi.encodePacked("MINTER_ROLE", id)))
    {
        require(tokens[id].created, "Token does not exist");

        _mint(account, id, amount, data);
    }

    function proposeToken(uint256 id) public onlyRole(TOKEN_PROPOSER_ROLE) {
        require(proposedTokens[id] == address(0), "Proposal already exists");
        require(!tokens[id].created, "Token already exists");
        proposedTokens[id] = _msgSender();
        INotifyOwnerChange(didRegistry).changeOwner(address(this), id, _msgSender());
        emit TokenProposed(id, _msgSender());
    }

    function cancelProposal(uint256 id) public {
        require(proposedTokens[id] != address(0) && !tokens[id].created, "Proposal not found");
        require(hasRole(ADMIN_ROLE, _msgSender()) || proposedTokens[id] == _msgSender(), "you cannot change this proposal");
        proposedTokens[id] = address(0);
        INotifyOwnerChange(didRegistry).changeOwner(address(this), id, address(0));
        emit ProposalCanceled(id);
    }

    function addToken(uint256 id, string memory tokenName, address minter)
        public
        onlyRole(ADMIN_ROLE)
    {
        require(!tokens[id].created, "Token already added");
        bytes32 MINTER_ROLE = keccak256(abi.encodePacked("MINTER_ROLE", id));
        if (proposedTokens[id] != address(0))
            proposedTokens[id] = address(0);

        _setRoleAdmin(MINTER_ROLE, ADMIN_ROLE);
        _setupRole(MINTER_ROLE, minter);

        INotifyOwnerChange(didRegistry).changeOwner(address(this), id, minter);

        tokens[id] = Token(id, tokenName, 0, true, "");
        tokenIds.push(id);

        emit TokenAdded(id, tokenName, minter);
    }

    function updateTokenName(uint256 id, string memory tokenName)
        public
        onlyRole(keccak256(abi.encodePacked("MINTER_ROLE", id)))
    {
        require(tokens[id].created, "Token does not exist");
        tokens[id].name = tokenName;
    }

    /**
     * @dev See {IERC1155-safeTransferFrom}.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public override {
        bytes32 MINTER_ROLE = keccak256(abi.encodePacked("MINTER_ROLE", id));
        require(transferAllowed(id, from, to) || hasRole(MINTER_ROLE, _msgSender()), "Transfer is not allowed");
        require(tokens[id].created, "Token does not exist");

        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not owner nor approved"
        );
        
        _safeTransferFrom(from, to, id, amount, data);
    }

    /**
     * @dev See {IERC1155-safeBatchTransferFrom}.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public override {
        for (uint256 i = 0; i < ids.length; ++i) {
            bytes32 MINTER_ROLE = keccak256(abi.encodePacked("MINTER_ROLE", ids[i]));
            require(transferAllowed(ids[i], from, to) || hasRole(MINTER_ROLE, _msgSender()), "Transfer is not allowed");
        }

        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: transfer caller is not owner nor approved"
        );

        _safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    // @notice burn function 
    function burn(
        address account,
        uint256 id,
        uint256 value
    ) public onlyRole(keccak256(abi.encodePacked("MINTER_ROLE", id))) {
        _burn(account, id, value);
    }

    function whitelistForClaim(address[] memory addresses, uint256[] memory values, uint256 tokenId) public onlyRole(ADMIN_ROLE) {
        require(tokens[tokenId].created, "Token does not exist");
        require(addresses.length == values.length);

        _whitelistForClaim(addresses, values, tokenId);
    }

    function mintBatch(
        address[] memory recipients,
        uint256 id,
        uint256[] memory amounts,
        bytes memory data
    ) public onlyRole(keccak256(abi.encodePacked("MINTER_ROLE", id))) {
        require(recipients.length == amounts.length, "ERC1155: destinations and amounts length mismatch");
        require(tokens[id].created, "Token does not exist");

        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "ERC1155: mint to the zero address");
            _mint(recipients[i], id, amounts[i], data);
        }
    }

    /**
     * @dev See {ERC1155-_beforeTokenTransfer}.
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                tokens[ids[i]].supply += amounts[i];
            }
        }

        if (to == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                tokens[ids[i]].supply -= amounts[i];
            }
        }
    }

    function getSupplyAndBalanceOfBatch(uint256[] memory ids, address account) public view returns (uint256[] memory supplies, uint256[] memory balances) {
        supplies = new uint256[](ids.length);
        balances = new uint256[](ids.length);

        for (uint256 i = 0; i < ids.length; ++i) {
            supplies[i] = tokens[ids[i]].supply;
            balances[i] = balanceOf(account, ids[i]);
        }
    }
}
