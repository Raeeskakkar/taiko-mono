// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
// import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AddressManager} from "../contracts/thirdparty/AddressManager.sol";
import {TaikoConfig} from "../contracts/L1/TaikoConfig.sol";
import {TaikoData} from "../contracts/L1/TaikoData.sol";
import {TaikoL1} from "../contracts/L1/TaikoL1.sol";
import {TaikoToken} from "../contracts/L1/TaikoToken.sol";
import {
    BlockHeader,
    LibBlockHeader
} from "../contracts/libs/LibBlockHeader.sol";
import {SignalService} from "../contracts/signal/SignalService.sol";

contract TaikoL1WithConfig is TaikoL1 {
    function getConfig()
        public
        pure
        override
        returns (TaikoData.Config memory config)
    {
        config = TaikoConfig.getConfig();
        config.maxNumBlocks = 5;
        config.maxVerificationsPerTx = 0;
    }
}

contract TaikoL1Test is Test {
    TaikoToken public tko;
    TaikoL1WithConfig public L1;
    SignalService public ss;

    bytes32 public constant GENESIS_BLOCK_HASH =
        keccak256("GENESIS_BLOCK_HASH");
    address public constant L2SS = 0xDAFEA492D9c6733ae3d56b7Ed1ADB60692c98Bc5;
    address public constant ALICE = 0xc8885E210E59Dba0164Ba7CDa25f607e6d586B7A;
    address public constant BOB = 0x000000000000000000636F6e736F6c652e6c6f67;

    address public constant VIB_100 =
        0xeD33259a056F4fb449FFB7B7E2eCB43a9B5685Bf;
    address public constant VB_100 = 0x5F927395213ee6b95dE97bDdCb1b2B1C0F16844F;

    AddressManager public addressManager;

    function setUp() public {
        addressManager = new AddressManager();
        addressManager.init();

        uint64 feeBase = 1E18;
        L1 = new TaikoL1WithConfig();
        L1.init(address(addressManager), GENESIS_BLOCK_HASH, feeBase);

        tko = new TaikoToken();
        tko.init(address(addressManager), "TaikoToken", "TKO");

        ss = new SignalService();
        ss.init(address(addressManager));

        // set proto_broker to this address to mint some TKO
        _registerAddress("proto_broker", address(this));
        tko.mint(address(this), 1E12 ether);

        // register all addresses
        _registerAddress("taiko_token", address(tko));
        _registerAddress("proto_broker", address(L1));
        _registerAddress("signal_service", address(ss));
        _registerL2Address("signal_service", address(L2SS));
        _registerAddress("bib_100", VIB_100);
        _registerAddress("vb_100", VB_100);
    }

    function proposeBlock(
        address proposer,
        uint256 txListSize
    ) internal returns (TaikoData.BlockMetadata memory meta) {
        uint64 gasLimit = 1000000;
        bytes memory txList = new bytes(txListSize);
        TaikoData.BlockMetadataInput memory input = TaikoData
            .BlockMetadataInput({
                beneficiary: proposer,
                gasLimit: gasLimit,
                txListHash: keccak256(txList)
            });

        TaikoData.StateVariables memory variables = L1.getStateVariables();

        uint256 mixHash;
        unchecked {
            mixHash = block.prevrandao * variables.nextBlockId;
        }

        meta.id = variables.nextBlockId;
        meta.l1Height = block.number - 1;
        meta.l1Hash = blockhash(block.number - 1);
        meta.beneficiary = proposer;
        meta.txListHash = keccak256(txList);
        meta.mixHash = bytes32(mixHash);
        meta.gasLimit = gasLimit;
        meta.timestamp = uint64(block.timestamp);

        vm.prank(proposer, proposer);
        bytes32 metaHash = L1.proposeBlock(input, txList);

        assertEq(metaHash, keccak256(abi.encode(meta)));
    }

    function proveBlock(
        address prover,
        TaikoData.Config memory conf,
        uint256 blockId,
        bytes32 parentHash,
        TaikoData.BlockMetadata memory meta
    ) internal returns (bytes32 blockHash) {
        bytes32[8] memory logsBloom;

        BlockHeader memory header = BlockHeader({
            parentHash: parentHash,
            ommersHash: LibBlockHeader.EMPTY_OMMERS_HASH,
            beneficiary: meta.beneficiary,
            stateRoot: bytes32(blockId + 200),
            transactionsRoot: bytes32(blockId + 201),
            receiptsRoot: bytes32(blockId + 202),
            logsBloom: logsBloom,
            difficulty: 0,
            height: uint128(blockId),
            gasLimit: uint64(meta.gasLimit + conf.anchorTxGasLimit),
            gasUsed: uint64(100),
            timestamp: meta.timestamp,
            extraData: new bytes(0),
            mixHash: bytes32(meta.mixHash),
            nonce: 0,
            baseFeePerGas: 10000
        });

        blockHash = LibBlockHeader.hashBlockHeader(header);

        TaikoData.ZKProof memory zkproof = TaikoData.ZKProof({
            data: new bytes(100),
            circuitId: 100
        });

        TaikoData.ValidBlockEvidence memory evidence = TaikoData
            .ValidBlockEvidence({
                meta: meta,
                zkproof: zkproof,
                header: header,
                signalRoot: bytes32(blockId + 400),
                prover: prover
            });
        vm.prank(prover, prover);
        L1.proveBlock(blockId, evidence);
    }

    function testProposeSingleBlock() external {
        _depositTaikoToken(ALICE, 1E6, 100);
        _depositTaikoToken(BOB, 1E6, 100);

        bytes32 parentHash = GENESIS_BLOCK_HASH;

        TaikoData.Config memory conf = L1.getConfig();
        for (uint blockId = 1; blockId < conf.maxNumBlocks * 3; blockId++) {
            TaikoData.BlockMetadata memory meta = proposeBlock(ALICE, 1024);
            // mockCall(VB_100, "", bytes(bytes32(true)));
            parentHash = proveBlock(BOB, conf, blockId, parentHash, meta);

            vm.prank(BOB, BOB);
            L1.verifyBlocks(1);
            // clearMockCalls();
            vm.roll(block.number + 1);
        }
    }

    function _registerAddress(string memory name, address addr) internal {
        string memory key = string.concat(
            Strings.toString(block.chainid),
            ".",
            name
        );
        addressManager.setAddress(key, addr);
    }

    function _registerL2Address(string memory name, address addr) internal {
        TaikoData.Config memory conf = L1.getConfig();
        string memory key = string.concat(
            Strings.toString(conf.chainId),
            ".",
            name
        );
        addressManager.setAddress(key, addr);
    }

    function _depositTaikoToken(
        address who,
        uint256 amountTko,
        uint amountEth
    ) private {
        vm.deal(who, amountEth * 1 ether);
        tko.transfer(who, amountTko * 1 ether);
        vm.prank(who, who);
        L1.deposit(amountTko);
    }
}
