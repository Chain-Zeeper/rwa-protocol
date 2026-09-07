// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// A stand-in for a Gnosis Safe, kept faithful to the parts the governance
// integration actually leans on, so these tests exercise real Safe encoding
// rather than a convenient approximation:
//
//   * checkSignatures takes `threshold` concatenated 65-byte {r,s,v} signatures
//     that must be ordered by strictly ascending owner address (Safe's GS026);
//   * execTransaction runs a call from the Safe's own address once the
//     threshold is met, which is how the "Safe executes the approval" route
//     reaches SafeDelegate with msg.sender == safe.
//
// Simplifications vs. the real thing: only v=27/28 ECDSA signatures (no
// pre-approved hashes, no eth_sign, no contract-owner signatures), no modules,
// guards, refunds or delegatecall, and a tx hash that is not Safe's exact
// SafeTx struct. None of that is load-bearing for what is under test.
contract MockSafe {
    address[] private _owners;
    mapping(address => bool) public isOwner;
    uint256 public threshold;
    uint256 public nonce;

    constructor(address[] memory owners_, uint256 threshold_) {
        require(threshold_ > 0 && threshold_ <= owners_.length, "GS201");
        for (uint256 i = 0; i < owners_.length; i++) {
            require(!isOwner[owners_[i]], "GS204");
            isOwner[owners_[i]] = true;
            _owners.push(owners_[i]);
        }
        threshold = threshold_;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    // owner management, so tests can move the electorate under a live proposal
    function addOwnerWithThreshold(address owner, uint256 threshold_) external {
        require(!isOwner[owner], "GS204");
        isOwner[owner] = true;
        _owners.push(owner);
        threshold = threshold_;
    }

    function removeOwner(address owner, uint256 threshold_) external {
        require(isOwner[owner], "GS203");
        isOwner[owner] = false;
        for (uint256 i = 0; i < _owners.length; i++) {
            if (_owners[i] == owner) {
                _owners[i] = _owners[_owners.length - 1];
                _owners.pop();
                break;
            }
        }
        require(threshold_ > 0 && threshold_ <= _owners.length, "GS201");
        threshold = threshold_;
    }

    function changeThreshold(uint256 threshold_) external {
        require(threshold_ > 0 && threshold_ <= _owners.length, "GS201");
        threshold = threshold_;
    }

    // ---------------------------------------------------------------
    // signatures
    // ---------------------------------------------------------------

    function checkSignatures(bytes32 dataHash, bytes memory signatures) public view {
        uint256 required = threshold;
        require(signatures.length >= required * 65, "GS020");

        address lastOwner = address(0);
        for (uint256 i = 0; i < required; i++) {
            (uint8 v, bytes32 r, bytes32 s) = _signatureSplit(signatures, i);
            require(v == 27 || v == 28, "GS021");
            address currentOwner = ecrecover(dataHash, v, r, s);
            // strictly ascending: also what stops the same owner counting twice
            require(currentOwner > lastOwner, "GS026");
            require(isOwner[currentOwner], "GS026");
            lastOwner = currentOwner;
        }
    }

    function _signatureSplit(bytes memory signatures, uint256 pos)
        private
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        assembly {
            let signaturePos := mul(0x41, pos)
            r := mload(add(signatures, add(signaturePos, 0x20)))
            s := mload(add(signatures, add(signaturePos, 0x40)))
            v := byte(0, mload(add(signatures, add(signaturePos, 0x60))))
        }
    }

    // ---------------------------------------------------------------
    // execution
    // ---------------------------------------------------------------

    function getTransactionHash(address to, uint256 value, bytes memory data, uint256 _nonce)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(address(this), block.chainid, to, value, keccak256(data), _nonce));
    }

    // Safe's MultiSend, in behaviour if not in encoding. The real thing is
    // delegatecalled, so it runs in the Safe's own context and every inner call
    // still carries msg.sender == the Safe; sequential calls from here are
    // equivalent for anything that only inspects the caller. This is what the
    // Transaction Builder produces whenever owners batch, and it is why a Safe
    // needs no special contract support to do several things atomically.
    function execTransactions(
        address[] memory to,
        uint256[] memory value,
        bytes[] memory data,
        bytes memory signatures
    ) external payable {
        checkSignatures(getTransactionHash(address(this), 0, abi.encode(to, value, data), nonce), signatures);
        nonce++;
        for (uint256 i = 0; i < to.length; i++) {
            (bool ok, bytes memory ret) = to[i].call{value: value[i]}(data[i]);
            if (!ok) {
                if (ret.length > 0) {
                    assembly { revert(add(ret, 0x20), mload(ret)) }
                }
                revert("GS013");
            }
        }
    }

    function execTransaction(address to, uint256 value, bytes memory data, bytes memory signatures)
        external
        payable
        returns (bool success)
    {
        checkSignatures(getTransactionHash(to, value, data, nonce), signatures);
        nonce++;
        bytes memory returndata;
        (success, returndata) = to.call{value: value}(data);
        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
            revert("GS013");
        }
    }

    receive() external payable {}
}
