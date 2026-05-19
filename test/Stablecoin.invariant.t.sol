// SPDX-License-Identifier: Apache-2.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {
    ERC1967Proxy
} from "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title StablecoinHandler
 * @notice Handler contract that exposes controlled actions for invariant testing.
 * The fuzzer will call these functions in random sequences to try to break invariants.
 */
contract StablecoinHandler is Test {
    Stablecoin public stablecoin;
    address public admin;
    address public minter;
    address public burner;
    address public freezer;

    // Ghost variables to track expected state
    uint256 public ghostTotalMinted;
    uint256 public ghostTotalBurned;
    uint256 public ghostMaxAllowanceGranted;
    address[] public actors;

    constructor(Stablecoin _stablecoin, address _admin, address _minter, address _burner, address _freezer) {
        stablecoin = _stablecoin;
        admin = _admin;
        minter = _minter;
        burner = _burner;
        freezer = _freezer;

        // Set up actors
        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        address recipient = actors[actorSeed % actors.length];
        uint256 allowance = stablecoin.minterAllowance(minter);

        // Only mint within allowance
        amount = bound(amount, 0, allowance);
        if (amount == 0) return;

        // Skip if minter or recipient is frozen
        if (stablecoin.frozen(minter) || stablecoin.frozen(recipient)) return;

        vm.prank(minter);
        stablecoin.mint(recipient, amount);
        ghostTotalMinted += amount;
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        address target = actors[actorSeed % actors.length];
        uint256 balance = stablecoin.balanceOf(target);

        // Only burn what exists
        amount = bound(amount, 0, balance);
        if (amount == 0) return;

        // Skip if any participant is frozen
        if (stablecoin.frozen(target) || stablecoin.frozen(burner)) return;

        // Transfer to burner first, then burn
        vm.prank(target);
        bool success = stablecoin.transfer(burner, amount);
        require(success, "transfer to burner failed");

        vm.prank(burner);
        stablecoin.burn(amount);
        ghostTotalBurned += amount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        if (from == to) return;

        uint256 balance = stablecoin.balanceOf(from);
        amount = bound(amount, 0, balance);
        if (amount == 0) return;

        // Skip if any participant is frozen
        if (stablecoin.frozen(from) || stablecoin.frozen(to)) return;

        vm.prank(from);
        bool success = stablecoin.transfer(to, amount);
        require(success, "transfer failed");
    }

    function freeze(uint256 actorSeed) external {
        address target = actors[actorSeed % actors.length];

        // Skip if already frozen
        if (stablecoin.frozen(target)) return;

        vm.prank(freezer);
        stablecoin.freeze(target);
    }

    function unfreeze(uint256 actorSeed) external {
        address target = actors[actorSeed % actors.length];

        // Skip if not frozen
        if (!stablecoin.frozen(target)) return;

        vm.prank(freezer);
        stablecoin.unfreeze(target);
    }

    function modifyMinterAllowance(int256 delta) external {
        int256 limit = int256(uint256(type(uint128).max));
        delta = bound(delta, -limit, limit);
        vm.prank(admin);
        stablecoin.modifyMinterAllowance(minter, delta);
        // Track the maximum allowance ever granted by admin (post-state after delta).
        uint256 newAllowance = stablecoin.minterAllowance(minter);
        if (newAllowance > ghostMaxAllowanceGranted) {
            ghostMaxAllowanceGranted = newAllowance;
        }
    }

    function setInitialMaxAllowance(uint256 initialAllowance) external {
        ghostMaxAllowanceGranted = initialAllowance;
    }

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }
}

/**
 * @title StablecoinInvariantTest
 * @notice Invariant tests verify properties that must ALWAYS hold, regardless of
 * what sequence of actions occur. The fuzzer will call handler functions in random
 * order trying to violate these invariants.
 */
contract StablecoinInvariantTest is Test {
    Stablecoin public stablecoin;
    StablecoinHandler public handler;

    address public constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public constant MINTER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant BURNER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address public constant PAUSER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address public constant FREEZER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    function setUp() public {
        vm.startPrank(ADMIN);
        Stablecoin impl = new Stablecoin();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Stablecoin.initialize, ("Stablecoin", "STBL", 6, ADMIN, BURNER, PAUSER, FREEZER))
        );
        stablecoin = Stablecoin(address(proxy));
        stablecoin.addMinter(MINTER, type(uint128).max); // Large allowance for testing
        vm.stopPrank();

        handler = new StablecoinHandler(stablecoin, ADMIN, MINTER, BURNER, FREEZER);
        // Initialize ghost variable with the initial allowance granted in setUp
        handler.setInitialMaxAllowance(type(uint128).max);

        // Tell Foundry which contract to call during invariant testing
        targetContract(address(handler));

        // Exclude setInitialMaxAllowance and getters from fuzzing - they're only for setup/assertions
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = StablecoinHandler.mint.selector;
        selectors[1] = StablecoinHandler.burn.selector;
        selectors[2] = StablecoinHandler.transfer.selector;
        selectors[3] = StablecoinHandler.modifyMinterAllowance.selector;
        selectors[4] = StablecoinHandler.freeze.selector;
        selectors[5] = StablecoinHandler.unfreeze.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /**
     * @notice Total supply must equal minted minus burned
     * This is the fundamental accounting invariant for any token.
     */
    function invariant_SupplyMatchesMintedMinusBurned() public view {
        assertEq(stablecoin.totalSupply(), handler.ghostTotalMinted() - handler.ghostTotalBurned());
    }

    /**
     * @notice Minter allowance can never exceed what was granted by admin
     * Tracks that allowance only decreases from minting, and any increase
     * must come from an explicit admin action (which updates our tracking).
     */
    function invariant_MinterAllowanceNeverExceedsGranted() public view {
        uint256 currentAllowance = stablecoin.minterAllowance(MINTER);
        uint256 maxGranted = handler.ghostMaxAllowanceGranted();
        assertLe(currentAllowance, maxGranted, "Allowance exceeds max ever granted by admin");
    }

    /**
     * @notice The number of minters must match the EnumerableMap length
     */
    function invariant_MinterCountMatchesGetAllMinters() public view {
        Stablecoin.MinterInfo[] memory minters = stablecoin.getAllMinters();
        assertEq(stablecoin.getMinterCount(), minters.length);
    }

    /**
     * @notice Sum of all actor balances plus burner balance must equal total supply
     * This validates that token conservation holds across all tracked accounts.
     */
    function invariant_ActorBalancesSumToSupply() public view {
        uint256 totalTracked = stablecoin.balanceOf(BURNER);
        uint256 actorCount = handler.getActorCount();
        for (uint256 i = 0; i < actorCount; i++) {
            totalTracked += stablecoin.balanceOf(handler.getActor(i));
        }
        // All tokens are either with actors or burner (minter starts with 0)
        assertEq(totalTracked, stablecoin.totalSupply());
    }

    /**
     * @notice Total minted must always be >= total burned
     * Cannot burn more tokens than have been created.
     */
    function invariant_MintedGreaterThanOrEqualBurned() public view {
        assertGe(handler.ghostTotalMinted(), handler.ghostTotalBurned());
    }
}
