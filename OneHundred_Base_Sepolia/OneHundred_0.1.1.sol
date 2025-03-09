// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Updated imports for Chainlink VRF 2.5
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

// Import for Chainlink Automation
// Directly include the interface to avoid import errors
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

// Import OpenZeppelin contracts for security
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// Removed Ownable import to avoid conflicts with VRFConsumerBaseV2Plus
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title OneHundred
 * @dev Number guessing game using Chainlink VRF 2.5 and Automation with optimized storage
 */
contract OneHundred is VRFConsumerBaseV2Plus, AutomationCompatibleInterface, ReentrancyGuard {
    using SafeMath for uint256;
    
    // Custom Errors
    error GamePaused();
    error RoundNotActive();
    error InClosingWindow();
    error ZeroNumbersSelected();
    error TooManySelections();
    error IncorrectPayment();
    error WouldExceedMaxSelections();
    error InvalidNumber();
    error NumberAlreadySelected();
    error NoPayouts();
    error TransferFailed();
    error RoundNotReadyToEnd();
    error NotReadyForNewRound();
    error InvalidRequestId();
    error NumberAlreadyGenerated();
    error InsufficientWithdrawableBalance();
    error ZeroWithdrawalAmount();
    error OwnerTransferFailed();
    error AdminControlsLocked();
    error WinnerPercentagesMustSum();
    error NoWinnerPercentagesMustSum();
    error ContractFeePercentageTooHigh();
    error InvalidRoundRange();
    error RoundExceedsCurrentRound();
    error StatisticsNotVisible();
    error InvalidCount();
    error EmergencyFundSweepFailed();
    error NumberGenerationFailed();
    error UnauthorizedUpkeep();
    error NotReadyForRandomGeneration();
    
    // Game states - Added AWAITING_RANDOM state for two-phase round ending
    enum GameState { WAITING_FOR_PLAYER, ACTIVE, AWAITING_RANDOM, REST }
    GameState public gameState;
    
    // Chainlink VRF variables - Updated for VRF 2.5
    uint256 private s_subscriptionId;
    bytes32 private s_keyHash;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant CALLBACK_GAS_LIMIT = 2500000;
    uint32 private constant NUM_WORDS = 1;
    mapping(uint256 => uint256) private s_requestIdToRoundNumber;
    
    // Chainlink Automation variables
    address public automationForwarder;
    
    // Flag constants for Round struct
    uint8 private constant FLAG_COMPLETED = 1;          // 00000001
    uint8 private constant FLAG_NUMBER_GENERATED = 2;   // 00000010
    uint8 private constant FLAG_ENTROPY_REQUESTED = 4;  // 00000100
    uint8 private constant FLAG_ROUND_ENDED = 8;        // 00001000 (New flag for round ended)
    
    // Game configuration grouped in structs
    struct GameConfig {
        uint256 roundDuration;
        uint256 restPeriod;
        uint256 selectionCost;
        uint8 maxSelectionsPerPlayer;
        uint8 totalNumbers;
        uint8 closingWindow;
    }
    
    struct PrizeConfig {
        uint16 winnerPercentage;
        uint16 runnerUpPercentage;
        uint16 noWinnerRunnerUpPercentage;
        uint16 houseWinnerSelectedPercentage;
        uint16 houseNoWinnerSelectedPercentage;
        uint16 contractFeePercentage;
    }
    
    struct SafetyConfig {
        uint256 vrfRequestBuffer;
        uint256 safetyBufferPercentage;
        bool statsVisibleToPlayers;
    }
    
    // Configuration instances
    GameConfig public gameConfig;
    PrizeConfig public prizeConfig;
    SafetyConfig public safetyConfig;
    
    // Game controls and state
    bool public gameActive = true;
    bool public adminControlsLocked = false;
    uint256 public currentRoundNumber = 0;
    uint256 public roundStartTime = 0;
    uint256 public roundEndTime = 0;
    
    // Data structures with optimized storage
    struct Round {
        uint256 startTime;
        uint256 endTime;
        uint256 potSize;
        uint8 winningNumber;
        address winner;
        address[2] runnerUps;
        uint8 flags; // bit 0: completed, bit 1: numberGenerated, bit 2: entropyRequested, bit 3: roundEnded
    }
    
    struct PlayerSelectionsForRound {
        uint8[] selectedNumbers;
        uint256 totalWagered;
        bool hasClaimed;
    }
    
    // Hot and cold numbers tracking
    uint8[] private hotNumbers;
    uint8[] private coldNumbers;
    mapping(uint8 => uint256) private numberFrequency;
    uint8 private constant MAX_STATS_SIZE = 20;
    
    // Mappings
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(uint8 => bool)) public isNumberSelected;
    mapping(uint256 => mapping(uint8 => address)) public numberToPlayer;
    mapping(uint256 => mapping(address => PlayerSelectionsForRound)) public playerSelectionsPerRound;
    mapping(address => uint256) public pendingPayouts;
    
    // Events - Added new events for debugging
    event RoundStarted(uint256 indexed roundNumber, uint256 startTime, uint256 endTime, address firstPlayer);
    event NumberSelected(address indexed player, uint256 indexed roundNumber, uint8[] numbers, uint256 cost);
    event RoundEnded(uint256 indexed roundNumber, uint256 endTime, uint256 potSize);
    event RandomNumberRequested(uint256 indexed roundNumber, uint256 requestId);
    event WinningNumberGenerated(uint256 indexed roundNumber, uint8 winningNumber);
    event PrizesDistributed(
        uint256 indexed roundNumber,
        address winner,
        address[2] runnerUps,
        uint256 winnerPrize,
        uint256 runnerUpPrize,
        bool winningNumberSelected
    );
    event WinningsClaimed(address indexed player, uint256 amount, uint256 roundNumber);
    event GameStateChanged(GameState previousState, GameState newState, uint256 timestamp);
    event ParametersUpdated(string parameterName, uint256 oldValue, uint256 newValue, address updater);
    event ContractFunded(address indexed sender, uint256 amount);
    event OwnerWithdrawal(uint256 amount);
    event EmergencyActionExecuted(string actionType, uint256 timestamp);
    event EmergencyFundSwept(uint256 indexed roundNumber, uint256 amount);
    event RandomWinnerGenerated(uint256 indexed roundNumber, uint8 winningNumber, string method);
    event UpkeepAttempted(address caller, uint256 timestamp, uint256 action);
    event UpkeepFailed(string reason);
    event AvailableNumbersReset(uint256 timestamp, uint256 nextRoundNumber);
    
    /**
     * @dev Constructor with Chainlink VRF 2.5 setup
     * @param vrfCoordinator The address of the VRF coordinator
     * @param subscriptionId The VRF subscription ID
     * @param keyHash The key hash for the VRF request
     */
    constructor(
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        // Set owner through the VRFConsumerBaseV2Plus constructor
        // Note: Removed Ownable(msg.sender) since VRFConsumerBaseV2Plus handles ownership
        
        s_subscriptionId = subscriptionId;
        s_keyHash = keyHash;
        gameState = GameState.WAITING_FOR_PLAYER;
        
        // Initialize configuration structs
        gameConfig = GameConfig({
            roundDuration: 600 seconds, // Default to 10 minutes for reliability
            restPeriod: 60 seconds,    // Default to 1 minute rest
            selectionCost: 0.001 ether,
            maxSelectionsPerPlayer: 10,
            totalNumbers: 100,
            closingWindow: 10
        });
        
        prizeConfig = PrizeConfig({
            winnerPercentage: 9000, // 90%
            runnerUpPercentage: 400, // 4%
            noWinnerRunnerUpPercentage: 2500, // 25%
            houseWinnerSelectedPercentage: 200, // 2%
            houseNoWinnerSelectedPercentage: 5000, // 50%
            contractFeePercentage: 0 // 0% (Changed from 10% to 0% for testing)
        });
        
        safetyConfig = SafetyConfig({
            vrfRequestBuffer: 15,
            safetyBufferPercentage: 20,
            statsVisibleToPlayers: true
        });
        
        // Initialize hot and cold arrays to be empty
        hotNumbers = new uint8[](0);
        coldNumbers = new uint8[](0);
    }
    
    receive() external payable {
        emit ContractFunded(msg.sender, msg.value);
    }
    
    fallback() external payable {
        emit ContractFunded(msg.sender, msg.value);
    }
    
    /**
     * @dev Required override for VRFConsumerBaseV2Plus
     * This forwards the request to our V2Plus implementation
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        fulfillRandomWordsV2Plus(requestId, randomWords, "");
    }
    
    /**
     * @dev Helper functions for Round struct flags
     */
    function _isCompleted(Round storage round) internal view returns (bool) {
        return (round.flags & FLAG_COMPLETED) != 0;
    }
    
    function _setCompleted(Round storage round) internal {
        round.flags |= FLAG_COMPLETED;
    }
    
    function _isNumberGenerated(Round storage round) internal view returns (bool) {
        return (round.flags & FLAG_NUMBER_GENERATED) != 0;
    }
    
    function _setNumberGenerated(Round storage round) internal {
        round.flags |= FLAG_NUMBER_GENERATED;
    }
    
    function _isEntropyRequested(Round storage round) internal view returns (bool) {
        return (round.flags & FLAG_ENTROPY_REQUESTED) != 0;
    }
    
    function _setEntropyRequested(Round storage round) internal {
        round.flags |= FLAG_ENTROPY_REQUESTED;
    }
    
    function _isRoundEnded(Round storage round) internal view returns (bool) {
        return (round.flags & FLAG_ROUND_ENDED) != 0;
    }
    
    function _setRoundEnded(Round storage round) internal {
        round.flags |= FLAG_ROUND_ENDED;
    }
    
    /**
     * @dev Helper function to sweep funds to owner during emergency operations
     */
    function _emergencySweepFunds(uint256 roundNumber) internal {
        Round storage round = rounds[roundNumber];
        
        if (round.potSize > 0) {
            uint256 amountSwept = round.potSize;
            round.potSize = 0;
            
            (bool success, ) = payable(owner()).call{value: amountSwept}("");
            if (!success) revert EmergencyFundSweepFailed();
            
            emit EmergencyFundSwept(roundNumber, amountSwept);
        }
    }
    
    /**
     * @dev Helper function to reset available numbers for the next round
     * This ensures all numbers are available at the start of a new round
     */
    function _resetAvailableNumbers(uint256 roundNumber) internal {
        // Reset the isNumberSelected mapping for the next round
        for (uint8 i = 1; i <= gameConfig.totalNumbers; i++) {
            isNumberSelected[roundNumber][i] = false;
        }
        
        // Emit an event to track when numbers were reset
        emit AvailableNumbersReset(block.timestamp, roundNumber);
    }
    
    /**
     * @dev Helper function to generate a pseudo-random winning number
     * @notice Only used in emergency operations, not for normal gameplay
     */
    function _generatePseudoRandomWinningNumber(uint256 roundNumber) internal returns (uint8) {
        if (roundNumber == 0 || roundNumber > currentRoundNumber) revert RoundExceedsCurrentRound();
        
        Round storage round = rounds[roundNumber];
        
        // Only generate number if not already generated
        if (_isNumberGenerated(round)) {
            return round.winningNumber;
        }
        
        // Generate pseudo-random number using block properties
        uint8 winningNumber = uint8(
            (uint256(
                keccak256(
                    abi.encodePacked(
                        blockhash(block.number - 1),
                        block.timestamp,
                        block.prevrandao,
                        roundNumber
                    )
                )
            ) % gameConfig.totalNumbers) + 1
        );
        
        round.winningNumber = winningNumber;
        _setNumberGenerated(round);
        
        // Update statistics tracking
        _updateHotColdNumbers(winningNumber);
        
        emit WinningNumberGenerated(roundNumber, winningNumber);
        emit RandomWinnerGenerated(roundNumber, winningNumber, "Emergency");
        
        return winningNumber;
    }
    
    /**
     * @dev Select numbers for the current round
     */
    function selectNumbers(uint8[] calldata numbers) external payable nonReentrant {
        if (!gameActive) revert GamePaused();
        
        if (gameState == GameState.WAITING_FOR_PLAYER) {
            _startNewRound(msg.sender);
        }
        
        if (gameState != GameState.ACTIVE) revert RoundNotActive();
        if (block.timestamp >= roundEndTime.sub(gameConfig.closingWindow)) revert InClosingWindow();
        if (numbers.length == 0) revert ZeroNumbersSelected();
        if (numbers.length > gameConfig.maxSelectionsPerPlayer) revert TooManySelections();
        if (msg.value != gameConfig.selectionCost.mul(numbers.length)) revert IncorrectPayment();
        
        PlayerSelectionsForRound storage playerSelections = playerSelectionsPerRound[currentRoundNumber][msg.sender];
        
        if (playerSelections.selectedNumbers.length.add(numbers.length) > gameConfig.maxSelectionsPerPlayer)
            revert WouldExceedMaxSelections();
        
        for (uint256 i = 0; i < numbers.length; i++) {
            uint8 number = numbers[i];
            
            if (number < 1 || number > gameConfig.totalNumbers) revert InvalidNumber();
            if (isNumberSelected[currentRoundNumber][number]) revert NumberAlreadySelected();
            
            isNumberSelected[currentRoundNumber][number] = true;
            numberToPlayer[currentRoundNumber][number] = msg.sender;
            playerSelections.selectedNumbers.push(number);
        }
        
        playerSelections.totalWagered = playerSelections.totalWagered.add(msg.value);
        rounds[currentRoundNumber].potSize = rounds[currentRoundNumber].potSize.add(msg.value);
        
        emit NumberSelected(msg.sender, currentRoundNumber, numbers, msg.value);
    }
    
    /**
     * @dev Claim pending payouts
     */
    function claimPayouts() external nonReentrant {
        uint256 amount = pendingPayouts[msg.sender];
        if (amount == 0) revert NoPayouts();
        
        pendingPayouts[msg.sender] = 0;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit WinningsClaimed(msg.sender, amount, currentRoundNumber);
    }
    
    /**
     * @dev Start a new round
     */
    function _startNewRound(address firstPlayer) internal {
        GameState previousState = gameState;
        gameState = GameState.ACTIVE;
        emit GameStateChanged(previousState, gameState, block.timestamp);
        
        currentRoundNumber = currentRoundNumber.add(1);
        roundStartTime = block.timestamp;
        roundEndTime = roundStartTime.add(gameConfig.roundDuration);
        
        rounds[currentRoundNumber] = Round({
            startTime: roundStartTime,
            endTime: roundEndTime,
            potSize: 0,
            winningNumber: 0,
            winner: address(0),
            runnerUps: [address(0), address(0)],
            flags: 0 // All flags start as false
        });
        
        emit RoundStarted(currentRoundNumber, roundStartTime, roundEndTime, firstPlayer);
    }
    
    /**
     * @dev End the current round - Split into two phases
     * Phase 1: End the round and transition to AWAITING_RANDOM
     */
    function _endRound() internal {
        Round storage round = rounds[currentRoundNumber];
        
        round.endTime = block.timestamp;
        _setRoundEnded(round);
        
        GameState previousState = gameState;
        gameState = GameState.AWAITING_RANDOM;
        emit GameStateChanged(previousState, gameState, block.timestamp);
        
        emit RoundEnded(currentRoundNumber, block.timestamp, round.potSize);
    }
    
    /**
     * @dev Request random number - Phase 2 of round end (Updated for VRF 2.5)
     */
    function _requestRandomNumber() internal {
        Round storage round = rounds[currentRoundNumber];
        
        if (round.potSize > 0) {
            // Updated to VRF 2.5 request format
            uint256 requestId = s_vrfCoordinator.requestRandomWords(
                VRFV2PlusClient.RandomWordsRequest({
                    keyHash: s_keyHash,
                    subId: s_subscriptionId,
                    requestConfirmations: REQUEST_CONFIRMATIONS,
                    callbackGasLimit: CALLBACK_GAS_LIMIT,
                    numWords: NUM_WORDS,
                    extraArgs: VRFV2PlusClient._argsToBytes(
                        VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                    )
                })
            );
            
            s_requestIdToRoundNumber[requestId] = currentRoundNumber;
            _setEntropyRequested(round);
            
            emit RandomNumberRequested(currentRoundNumber, requestId);
            
            GameState previousState = gameState;
            gameState = GameState.REST;
            emit GameStateChanged(previousState, gameState, block.timestamp);
        } else {
            _setCompleted(round);
            
            GameState previousState = gameState;
            gameState = GameState.REST;
            emit GameStateChanged(previousState, gameState, block.timestamp);
        }
    }
    
    /**
     * @dev Update hot and cold numbers tracking
     */
    function _updateHotColdNumbers(uint8 winningNumber) internal {
        // Increment winning number frequency
        numberFrequency[winningNumber] = numberFrequency[winningNumber].add(1);
        
        // Rebuild hot and cold arrays - more efficient for infrequent updates
        uint8[] memory allNumbers = new uint8[](gameConfig.totalNumbers);
        uint256[] memory frequencies = new uint256[](gameConfig.totalNumbers);
        
        // Collect all frequencies
        for (uint8 i = 1; i <= gameConfig.totalNumbers; i++) {
            allNumbers[i-1] = i;
            frequencies[i-1] = numberFrequency[i];
        }
        
        // Simple selection sort (efficient for small arrays)
        uint8 maxStatsSize = MAX_STATS_SIZE > gameConfig.totalNumbers ? 
                           gameConfig.totalNumbers : MAX_STATS_SIZE;
        
        // Sort for hot numbers (highest frequencies first)
        for (uint256 i = 0; i < maxStatsSize; i++) {
            uint256 maxIndex = i;
            for (uint256 j = i + 1; j < gameConfig.totalNumbers; j++) {
                if (frequencies[j] > frequencies[maxIndex]) {
                    maxIndex = j;
                }
            }
            if (maxIndex != i) {
                // Swap frequencies
                uint256 tempFreq = frequencies[i];
                frequencies[i] = frequencies[maxIndex];
                frequencies[maxIndex] = tempFreq;
                
                // Swap numbers
                uint8 tempNum = allNumbers[i];
                allNumbers[i] = allNumbers[maxIndex];
                allNumbers[maxIndex] = tempNum;
            }
        }
        
        // Update hot numbers array
        delete hotNumbers; // Clear the array
        hotNumbers = new uint8[](maxStatsSize);
        for (uint256 i = 0; i < maxStatsSize; i++) {
            hotNumbers[i] = allNumbers[i];
        }
        
        // For cold numbers, we use the end of the sorted array
        delete coldNumbers; // Clear the array
        coldNumbers = new uint8[](maxStatsSize);
        for (uint256 i = 0; i < maxStatsSize; i++) {
            coldNumbers[i] = allNumbers[gameConfig.totalNumbers - 1 - i];
        }
    }
    
    /**
     * @dev VRF callback (Updated for VRF 2.5)
     */
    function fulfillRandomWordsV2Plus(
        uint256 requestId,
        uint256[] memory randomWords,
        bytes memory
    ) internal {
        // Parameter name removed entirely to properly silence the unused parameter warning
        
        uint256 roundNumber = s_requestIdToRoundNumber[requestId];
        
        if (roundNumber == 0) revert InvalidRequestId();
        
        Round storage round = rounds[roundNumber];
        if (_isNumberGenerated(round)) revert NumberAlreadyGenerated();
        
        uint8 winningNumber = uint8((randomWords[0] % gameConfig.totalNumbers) + 1);
        
        round.winningNumber = winningNumber;
        _setNumberGenerated(round);
        
        // Update statistics tracking
        _updateHotColdNumbers(winningNumber);
        
        emit WinningNumberGenerated(roundNumber, winningNumber);
        
        _determineWinnersAndDistributePrizes(roundNumber, winningNumber);
    }
    
    /**
     * @dev Chainlink Automation checkUpkeep - Following best practices
     * This function checks if an upkeep is needed based on the current state of the contract
     */
    function checkUpkeep(bytes calldata checkData) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData) 
    {
        // Explicitly process the checkData parameter (even though we may not use it)
        // This makes the interface more compatible with all Chainlink Registries
        // Avoid type mismatch by using proper bytes handling
        bytes memory processedData = new bytes(checkData.length);
        if (checkData.length > 0) {
            for (uint i = 0; i < checkData.length; i++) {
                processedData[i] = checkData[i];
            }
        }
        
        // Case 1: Round has ended and needs to transition to AWAITING_RANDOM state
        if (gameState == GameState.ACTIVE && block.timestamp >= roundEndTime) {
            return (true, abi.encode(1));
        } 
        // Case 2: Round is in AWAITING_RANDOM state and needs to request randomness
        else if (gameState == GameState.AWAITING_RANDOM) {
            Round storage round = rounds[currentRoundNumber];
            if (_isRoundEnded(round) && !_isEntropyRequested(round)) {
                return (true, abi.encode(2));
            }
        }
        // Case 3: Rest period has finished and winning number has been generated
        else if (gameState == GameState.REST) {
            Round storage round = rounds[currentRoundNumber];
            if (block.timestamp >= round.endTime.add(gameConfig.restPeriod) && _isNumberGenerated(round)) {
                return (true, abi.encode(3));
            }
        }
        
        // Use processedData to avoid compiler warnings
        if (processedData.length > 0) {
            // This is just to make the compiler happy, we don't actually use the data
        }
        
        return (false, "");
    }
    
    /**
     * @dev Chainlink Automation performUpkeep with authorization
     * This function is called by the Chainlink Automation network when checkUpkeep returns true
     * Validate conditions again to prevent issues with race conditions
     */
    function performUpkeep(bytes calldata performData) external override {
        // Add authentication check
        if (automationForwarder != address(0) && msg.sender != automationForwarder) {
            emit UpkeepFailed("Unauthorized caller");
            revert UnauthorizedUpkeep();
        }
        
        // Log upkeep attempt
        uint256 action = abi.decode(performData, (uint256));
        emit UpkeepAttempted(msg.sender, block.timestamp, action);
        
        if (action == 1) {
            // Revalidate conditions for ending a round
            if (gameState != GameState.ACTIVE || block.timestamp < roundEndTime) {
                emit UpkeepFailed("Round not ready to end");
                revert RoundNotReadyToEnd();
            }
            _endRound();
        } else if (action == 2) {
            // Revalidate conditions for requesting random number
            Round storage round = rounds[currentRoundNumber];
            if (gameState != GameState.AWAITING_RANDOM || !_isRoundEnded(round) || _isEntropyRequested(round)) {
                emit UpkeepFailed("Not ready for random generation");
                revert NotReadyForRandomGeneration();
            }
            _requestRandomNumber();
        } else if (action == 3) {
            // Revalidate conditions for starting a new round after rest
            Round storage round = rounds[currentRoundNumber];
            if (gameState != GameState.REST || 
                block.timestamp < round.endTime.add(gameConfig.restPeriod) || 
                !_isNumberGenerated(round)) {
                emit UpkeepFailed("Not ready for new round");
                revert NotReadyForNewRound();
            }
            
            // CHANGE: Reset available numbers for the next round BEFORE transitioning to WAITING_FOR_PLAYER
            // This ensures that when the game enters WAITING_FOR_PLAYER, all numbers are already available
            _resetAvailableNumbers(currentRoundNumber + 1);
            
            GameState previousState = gameState;
            gameState = GameState.WAITING_FOR_PLAYER;
            emit GameStateChanged(previousState, gameState, block.timestamp);
        }
    }
    
    /**
     * @dev Helper min function
     */
    function min(uint8 a, uint8 b) private pure returns (uint8) {
        return a < b ? a : b;
    }
    
    /**
     * @dev Determine winners and distribute prizes
     */
    function _determineWinnersAndDistributePrizes(uint256 roundNumber, uint8 winningNumber) internal {
        Round storage round = rounds[roundNumber];
        uint256 potSize = round.potSize;
        
        if (potSize == 0) {
            _setCompleted(round);
            return;
        }
        
        address mainWinner = numberToPlayer[roundNumber][winningNumber];
        
        address[2] memory runnerUps = [address(0), address(0)];
        uint8[2] memory closestDistances = [type(uint8).max, type(uint8).max];
        
        for (uint8 i = 1; i <= gameConfig.totalNumbers; i++) {
            if (i == winningNumber) continue;
            
            address player = numberToPlayer[roundNumber][i];
            if (player == address(0)) continue;
            
            uint8 distance;
            if (i > winningNumber) {
                distance = min(i - winningNumber, winningNumber + gameConfig.totalNumbers - i);
            } else {
                distance = min(winningNumber - i, i + gameConfig.totalNumbers - winningNumber);
            }
            
            if (distance < closestDistances[0]) {
                closestDistances[1] = closestDistances[0];
                runnerUps[1] = runnerUps[0];
                
                closestDistances[0] = distance;
                runnerUps[0] = player;
            } else if (distance < closestDistances[1]) {
                closestDistances[1] = distance;
                runnerUps[1] = player;
            }
        }
        
        uint256 mainPrize;
        uint256 runnerUpPrize;
        uint256 housePrize;
        
        if (mainWinner != address(0)) {
            mainPrize = potSize.mul(prizeConfig.winnerPercentage).div(10000);
            runnerUpPrize = potSize.mul(prizeConfig.runnerUpPercentage).div(10000);
            housePrize = potSize.mul(prizeConfig.houseWinnerSelectedPercentage).div(10000);
            
            pendingPayouts[mainWinner] = pendingPayouts[mainWinner].add(mainPrize);
            round.winner = mainWinner;
        } else {
            mainPrize = 0;
            runnerUpPrize = potSize.mul(prizeConfig.noWinnerRunnerUpPercentage).div(10000);
            housePrize = potSize.mul(prizeConfig.houseNoWinnerSelectedPercentage).div(10000);
        }
        
        uint256 totalRunnerUpPrize = 0;
        for (uint8 i = 0; i < 2; i++) {
            if (runnerUps[i] != address(0)) {
                pendingPayouts[runnerUps[i]] = pendingPayouts[runnerUps[i]].add(runnerUpPrize);
                totalRunnerUpPrize = totalRunnerUpPrize.add(runnerUpPrize);
            } else {
                housePrize = housePrize.add(runnerUpPrize);
            }
        }
        
        round.runnerUps = runnerUps;
        
        if (housePrize > 0) {
            uint256 contractPortion = housePrize.mul(prizeConfig.contractFeePercentage).div(10000);
            uint256 ownerPortion = housePrize.sub(contractPortion);
            
            if (ownerPortion > 0) {
                (bool success, ) = payable(owner()).call{value: ownerPortion}("");
                if (!success) revert OwnerTransferFailed();
            }
        }
        
        _setCompleted(round);
        
        emit PrizesDistributed(
            roundNumber,
            mainWinner,
            runnerUps,
            mainPrize,
            runnerUpPrize,
            mainWinner != address(0)
        );
    }
    
    /**
     * @dev Get minimum required balance
     */
    function getMinimumRequiredBalance() public view returns (uint256) {
        return address(this).balance.mul(safetyConfig.safetyBufferPercentage).div(100);
    }
    
    /**
     * @dev Owner withdrawal
     */
    function ownerWithdraw(uint256 amount) external onlyOwner nonReentrant {
        uint256 minBalance = getMinimumRequiredBalance();
        uint256 contractBalance = address(this).balance;
        
        uint256 maxWithdrawable = 0;
        if (contractBalance > minBalance) {
            maxWithdrawable = contractBalance.sub(minBalance);
        }
        
        if (amount > maxWithdrawable) revert InsufficientWithdrawableBalance();
        if (amount == 0) revert ZeroWithdrawalAmount();
        
        (bool success, ) = payable(owner()).call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit OwnerWithdrawal(amount);
    }
    
    /*************************
     * ADMIN CONTROL FUNCTIONS
     *************************/
    
    /**
     * @dev Update game parameters
     */
    function updateGameParameters(
        uint256 _roundDuration,
        uint256 _restPeriod,
        uint256 _selectionCost,
        uint8 _maxSelectionsPerPlayer,
        uint8 _closingWindow
    ) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        emit ParametersUpdated("roundDuration", gameConfig.roundDuration, _roundDuration, msg.sender);
        emit ParametersUpdated("restPeriod", gameConfig.restPeriod, _restPeriod, msg.sender);
        emit ParametersUpdated("selectionCost", gameConfig.selectionCost, _selectionCost, msg.sender);
        emit ParametersUpdated("maxSelectionsPerPlayer", gameConfig.maxSelectionsPerPlayer, _maxSelectionsPerPlayer, msg.sender);
        emit ParametersUpdated("closingWindow", gameConfig.closingWindow, _closingWindow, msg.sender);
        
        gameConfig.roundDuration = _roundDuration;
        gameConfig.restPeriod = _restPeriod;
        gameConfig.selectionCost = _selectionCost;
        gameConfig.maxSelectionsPerPlayer = _maxSelectionsPerPlayer;
        gameConfig.closingWindow = _closingWindow;
    }
    
    /**
     * @dev Update prize parameters
     */
    function updatePrizeParameters(
        uint16 _winnerPercentage,
        uint16 _runnerUpPercentage,
        uint16 _noWinnerRunnerUpPercentage,
        uint16 _houseWinnerSelectedPercentage,
        uint16 _houseNoWinnerSelectedPercentage,
        uint16 _contractFeePercentage
    ) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        if (_winnerPercentage + (_runnerUpPercentage * 2) + _houseWinnerSelectedPercentage != 10000)
            revert WinnerPercentagesMustSum();
        if ((_noWinnerRunnerUpPercentage * 2) + _houseNoWinnerSelectedPercentage != 10000)
            revert NoWinnerPercentagesMustSum();
        if (_contractFeePercentage > 10000) 
            revert ContractFeePercentageTooHigh();
        
        emit ParametersUpdated("winnerPercentage", prizeConfig.winnerPercentage, _winnerPercentage, msg.sender);
        emit ParametersUpdated("runnerUpPercentage", prizeConfig.runnerUpPercentage, _runnerUpPercentage, msg.sender);
        emit ParametersUpdated("noWinnerRunnerUpPercentage", prizeConfig.noWinnerRunnerUpPercentage, _noWinnerRunnerUpPercentage, msg.sender);
        emit ParametersUpdated("houseWinnerSelectedPercentage", prizeConfig.houseWinnerSelectedPercentage, _houseWinnerSelectedPercentage, msg.sender);
        emit ParametersUpdated("houseNoWinnerSelectedPercentage", prizeConfig.houseNoWinnerSelectedPercentage, _houseNoWinnerSelectedPercentage, msg.sender);
        emit ParametersUpdated("contractFeePercentage", prizeConfig.contractFeePercentage, _contractFeePercentage, msg.sender);
        
        prizeConfig.winnerPercentage = _winnerPercentage;
        prizeConfig.runnerUpPercentage = _runnerUpPercentage;
        prizeConfig.noWinnerRunnerUpPercentage = _noWinnerRunnerUpPercentage;
        prizeConfig.houseWinnerSelectedPercentage = _houseWinnerSelectedPercentage;
        prizeConfig.houseNoWinnerSelectedPercentage = _houseNoWinnerSelectedPercentage;
        prizeConfig.contractFeePercentage = _contractFeePercentage;
    }
    
    /**
     * @dev Update VRF parameters
     */
    function updateVrfParameters(
        uint256 subscriptionId,
        bytes32 keyHash
    ) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        emit ParametersUpdated("subscriptionId", s_subscriptionId, subscriptionId, msg.sender);
        
        s_subscriptionId = subscriptionId;
        s_keyHash = keyHash;
    }
    
    /**
     * @dev Update safety parameters
     */
    function updateSafetyParameters(
        uint256 _vrfRequestBuffer,
        uint256 _safetyBufferPercentage
    ) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        emit ParametersUpdated("vrfRequestBuffer", safetyConfig.vrfRequestBuffer, _vrfRequestBuffer, msg.sender);
        emit ParametersUpdated("safetyBufferPercentage", safetyConfig.safetyBufferPercentage, _safetyBufferPercentage, msg.sender);
        
        safetyConfig.vrfRequestBuffer = _vrfRequestBuffer;
        safetyConfig.safetyBufferPercentage = _safetyBufferPercentage;
    }
    
    /**
     * @dev Set game active/paused
     */
    function setGameActive(bool _gameActive) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        gameActive = _gameActive;
        
        emit ParametersUpdated("gameActive", gameActive ? 1 : 0, _gameActive ? 1 : 0, msg.sender);
    }
    
    /**
     * @dev Set stats visibility
     */
    function setStatsVisibleToPlayers(bool _statsVisibleToPlayers) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        safetyConfig.statsVisibleToPlayers = _statsVisibleToPlayers;
        
        emit ParametersUpdated("statsVisibleToPlayers", safetyConfig.statsVisibleToPlayers ? 1 : 0, _statsVisibleToPlayers ? 1 : 0, msg.sender);
    }
    
    /**
     * @dev Set the Chainlink Automation forwarder address
     * @notice This follows Chainlink's best practice for securing performUpkeep
     */
    function setAutomationForwarder(address _forwarder) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        automationForwarder = _forwarder;
        
        emit ParametersUpdated("automationForwarder", 0, uint256(uint160(_forwarder)), msg.sender);
    }
    
    /**
     * @dev Lock admin controls permanently
     */
    function lockAdminControls() external onlyOwner {
        adminControlsLocked = true;
        
        emit ParametersUpdated("adminControlsLocked", 0, 1, msg.sender);
    }
    
    /**
     * @dev Emergency withdrawal for testing - no safety buffer restriction
     */
    function emergencyWithdrawAll() external onlyOwner nonReentrant {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        uint256 amount = address(this).balance;
        if (amount == 0) revert ZeroWithdrawalAmount();
        
        (bool success, ) = payable(owner()).call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit OwnerWithdrawal(amount);
        emit EmergencyActionExecuted("WithdrawAll", block.timestamp);
    }
    
    /**
     * @dev Emergency withdrawal (legacy function)
     */
    function emergencyWithdraw() external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        uint256 amount = address(this).balance;
        
        (bool success, ) = payable(owner()).call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit OwnerWithdrawal(amount);
    }
    
    /***************************
     * EMERGENCY STATE FUNCTIONS
     ***************************/
    
    /**
     * @dev Separate function to sweep funds from a round
     * @notice Used for emergency management without changing game state
     */
    function emergencySweepRoundFunds(uint256 roundNumber) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        if (roundNumber > currentRoundNumber) revert RoundExceedsCurrentRound();
        
        _emergencySweepFunds(roundNumber);
        emit EmergencyActionExecuted("SweepRoundFunds", block.timestamp);
    }
    
    /**
     * @dev Force transition to a specific game state
     * @notice This emergency function allows recovering from a stuck state
     * @param newState The desired game state
     * @param generateRandomWinner Whether to generate a random winner for the current round
     */
    function emergencyForceState(GameState newState, bool generateRandomWinner) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        // If requested and applicable, generate a random winning number
        if (generateRandomWinner && currentRoundNumber > 0) {
            Round storage round = rounds[currentRoundNumber];
            if (!_isNumberGenerated(round) && round.potSize > 0) {
                uint8 winningNumber = _generatePseudoRandomWinningNumber(currentRoundNumber);
                _determineWinnersAndDistributePrizes(currentRoundNumber, winningNumber);
            }
        }
        
        // If transitioning to WAITING_FOR_PLAYER, reset available numbers for the next round
        if (newState == GameState.WAITING_FOR_PLAYER) {
            _resetAvailableNumbers(currentRoundNumber + 1);
        }
        
        GameState previousState = gameState;
        gameState = newState;
        
        emit GameStateChanged(previousState, newState, block.timestamp);
        emit EmergencyActionExecuted("ForceState", block.timestamp);
    }
    
    /**
     * @dev Force complete a specific round
     * @notice This emergency function allows resolving a stuck round
     * @param roundNumber The round to complete
     * @param generateRandomWinner Whether to generate a random winner
     */
    function emergencyCompleteRound(uint256 roundNumber, bool generateRandomWinner) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        if (roundNumber > currentRoundNumber) revert RoundExceedsCurrentRound();
        
        Round storage round = rounds[roundNumber];
        
        // Handle round completion based on flag parameter
        if (generateRandomWinner && !_isNumberGenerated(round) && round.potSize > 0) {
            // Generate a random number and distribute prizes
            uint8 winningNumber = _generatePseudoRandomWinningNumber(roundNumber);
            _determineWinnersAndDistributePrizes(roundNumber, winningNumber);
        } else {
            // Just mark as completed without distributing prizes
            if (!_isCompleted(round)) {
                _setCompleted(round);
            }
        }
        
        emit EmergencyActionExecuted("CompleteRound", block.timestamp);
    }
    
    /**
     * @dev Reset the game to initial state
     * @notice This emergency function allows completely resetting the game state
     * @param generateRandomWinner Whether to generate a random winner for the current round before resetting
     */
    function emergencyResetGame(bool generateRandomWinner) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        // If requested and applicable, generate a random winning number for current round
        if (generateRandomWinner && currentRoundNumber > 0) {
            Round storage round = rounds[currentRoundNumber];
            if (!_isNumberGenerated(round) && round.potSize > 0) {
                uint8 winningNumber = _generatePseudoRandomWinningNumber(currentRoundNumber);
                _determineWinnersAndDistributePrizes(currentRoundNumber, winningNumber);
            }
        }
        
        // Reset game to initial state
        gameState = GameState.WAITING_FOR_PLAYER;
        
        // Complete the current round if not already completed
        if (currentRoundNumber > 0) {
            Round storage round = rounds[currentRoundNumber];
            if (!_isCompleted(round)) {
                _setCompleted(round);
            }
        }
        
        // Reset timers
        roundStartTime = 0;
        roundEndTime = 0;
        
        // Reset available numbers for the next round
        _resetAvailableNumbers(currentRoundNumber + 1);
        
        emit EmergencyActionExecuted("ResetGame", block.timestamp);
        emit GameStateChanged(GameState.ACTIVE, GameState.WAITING_FOR_PLAYER, block.timestamp);
    }
    
    /**
     * @dev Force execute upkeep
     * @notice Allows manually triggering the automation logic
     * @param action The upkeep action to perform (1=end round, 2=request random, 3=start new round)
     * @param generateRandomWinner Whether to generate a random winner if needed
     */
    function emergencyPerformUpkeep(uint256 action, bool generateRandomWinner) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        
        if (action == 1) {
            _endRound();
        } else if (action == 2) {
            _requestRandomNumber();
        } else if (action == 3) {
            // If we're transitioning from REST to WAITING, check if we need a random number
            if (gameState == GameState.REST && generateRandomWinner) {
                Round storage round = rounds[currentRoundNumber];
                if (!_isNumberGenerated(round) && round.potSize > 0) {
                    uint8 winningNumber = _generatePseudoRandomWinningNumber(currentRoundNumber);
                    _determineWinnersAndDistributePrizes(currentRoundNumber, winningNumber);
                }
            }
            
            // Reset available numbers for the next round BEFORE transitioning to WAITING_FOR_PLAYER
            _resetAvailableNumbers(currentRoundNumber + 1);
            
            GameState previousState = gameState;
            gameState = GameState.WAITING_FOR_PLAYER;
            emit GameStateChanged(previousState, gameState, block.timestamp);
        }
        
        emit EmergencyActionExecuted("PerformUpkeep", block.timestamp);
    }
    
    /**
     * @dev Emergency function to manually reset available numbers
     * @notice This helps recover from issues with available numbers not resetting
     * @param roundNumber The round number to reset numbers for
     */
    function emergencyResetAvailableNumbers(uint256 roundNumber) external onlyOwner {
        if (adminControlsLocked) revert AdminControlsLocked();
        if (roundNumber > currentRoundNumber + 1) revert RoundExceedsCurrentRound();
        
        _resetAvailableNumbers(roundNumber);
        emit EmergencyActionExecuted("ResetAvailableNumbers", block.timestamp);
    }
    
    /***********************
     * VIEW/GETTER FUNCTIONS
     ***********************/
    
    /**
     * @dev Get round info
     */
    function getRoundInfo(uint256 roundNumber) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 potSize,
        uint8 winningNumber,
        address winner,
        address[2] memory runnerUps,
        bool completed,
        bool numberGenerated
    ) {
        Round storage round = rounds[roundNumber];
        
        return (
            round.startTime,
            round.endTime,
            round.potSize,
            round.winningNumber,
            round.winner,
            round.runnerUps,
            _isCompleted(round),
            _isNumberGenerated(round)
        );
    }
    
    /**
     * @dev Get current game state
     */
    function getGameState() external view returns (
        uint256 roundNum,
        uint256 timeRemaining,
        uint256 currentPot,
        GameState state
    ) {
        roundNum = currentRoundNumber;
        currentPot = rounds[currentRoundNumber].potSize;
        state = gameState;
        
        if (gameState == GameState.ACTIVE) {
            timeRemaining = roundEndTime > block.timestamp ? roundEndTime - block.timestamp : 0;
        } else if (gameState == GameState.REST) {
            Round storage round = rounds[currentRoundNumber];
            timeRemaining = round.endTime.add(gameConfig.restPeriod) > block.timestamp ? 
                          round.endTime.add(gameConfig.restPeriod) - block.timestamp : 0;
        } else {
            timeRemaining = 0;
        }
        
        return (roundNum, timeRemaining, currentPot, state);
    }
    
    /**
     * @dev Get player selections
     */
    function getPlayerSelectionsForRound(address player, uint256 roundNumber) 
        external 
        view 
        returns (uint8[] memory, uint256, bool) 
    {
        PlayerSelectionsForRound storage selections = playerSelectionsPerRound[roundNumber][player];
        return (selections.selectedNumbers, selections.totalWagered, selections.hasClaimed);
    }
    
    /**
     * @dev Get available numbers
     */
    function getAvailableNumbers() external view returns (uint8[] memory) {
        uint256 availableCount = 0;
        for (uint8 i = 1; i <= gameConfig.totalNumbers; i++) {
            if (!isNumberSelected[currentRoundNumber][i]) {
                availableCount++;
            }
        }
        
        uint8[] memory available = new uint8[](availableCount);
        uint256 index = 0;
        
        for (uint8 i = 1; i <= gameConfig.totalNumbers; i++) {
            if (!isNumberSelected[currentRoundNumber][i]) {
                available[index] = i;
                index++;
            }
        }
        
        return available;
    }
    
    /**
     * @dev Get contract balance
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    /**
     * @dev Get hot and cold numbers - optimized to use precomputed arrays
     */
    function getHotColdNumbers(uint8 count) external view returns (
        uint8[] memory hot,
        uint8[] memory cold
    ) {
        if (!safetyConfig.statsVisibleToPlayers && msg.sender != owner()) revert StatisticsNotVisible();
        if (count == 0 || count > MAX_STATS_SIZE) revert InvalidCount();
        
        // Use the most recent computation with a fixed size
        uint8 actualCount = count;
        if (actualCount > hotNumbers.length) {
            actualCount = uint8(hotNumbers.length);
        }
        
        hot = new uint8[](actualCount);
        cold = new uint8[](actualCount);
        
        for (uint8 i = 0; i < actualCount; i++) {
            hot[i] = hotNumbers[i];
            cold[i] = coldNumbers[i];
        }
        
        return (hot, cold);
    }
    
    /**
     * @dev Get player history
     */
    function getPlayerHistory(address player, uint256 startRound, uint256 endRound) 
        external 
        view 
        returns (
            uint256[] memory roundNumbers,
            uint8[][] memory selections,
            uint256[] memory wagered
        ) 
    {
        if (startRound > endRound) revert InvalidRoundRange();
        if (endRound > currentRoundNumber) revert RoundExceedsCurrentRound();
        
        uint256 count = endRound - startRound + 1;
        
        roundNumbers = new uint256[](count);
        selections = new uint8[][](count);
        wagered = new uint256[](count);
        
        uint256 index = 0;
        for (uint256 roundNum = startRound; roundNum <= endRound; roundNum++) {
            PlayerSelectionsForRound storage playerSelections = playerSelectionsPerRound[roundNum][player];
            
            if (playerSelections.selectedNumbers.length > 0) {
                roundNumbers[index] = roundNum;
                selections[index] = playerSelections.selectedNumbers;
                wagered[index] = playerSelections.totalWagered;
                index++;
            }
        }
        
        return (roundNumbers, selections, wagered);
    }
    
    /**
     * @dev Get recent rounds
     */
    function getRecentRounds(uint8 count)
        external
        view
        returns (
            uint256[] memory roundNumbers,
            uint8[] memory winningNumbers,
            uint256[] memory potSizes,
            address[] memory winners
        )
    {
        uint256 startRound = currentRoundNumber >= count ? currentRoundNumber - count + 1 : 1;
        uint256 roundCount = currentRoundNumber >= count ? count : currentRoundNumber;
        
        roundNumbers = new uint256[](roundCount);
        winningNumbers = new uint8[](roundCount);
        potSizes = new uint256[](roundCount);
        winners = new address[](roundCount);
        
        uint256 index = 0;
        for (uint256 roundNum = startRound; roundNum <= currentRoundNumber; roundNum++) {
            Round storage round = rounds[roundNum];
            
            if (_isCompleted(round)) {
                roundNumbers[index] = roundNum;
                winningNumbers[index] = round.winningNumber;
                potSizes[index] = round.potSize;
                winners[index] = round.winner;
                index++;
            }
        }
        
        return (roundNumbers, winningNumbers, potSizes, winners);
    }
}