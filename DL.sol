// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./common/IPancake.sol";


interface IStakeContract {
    function updateFeeNodesDL(uint256 amount,uint256 _type) external;
    function getParentUserInfo(address user) external view returns( address my_address, uint256 is_jihuo, uint256 is_jihuo_p,uint256 group_rank2 );
}

contract DLToken is ERC20, Ownable, ReentrancyGuard {
    uint256 private  constant TOTAL_SUPPLY = 210000000 * 10**18;
    uint256 private constant MIN_POOL_VALUE = 2_000_000 * 10**18;
    uint256 private constant MIN_POOL_VALUE2 = 1_500_000 * 10**18;
    uint256 public MAX_POOL_VALUE;//最大市值
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public poolValue;


    address public interactiveContract;
    address public foundationAddress;
    address public pancakePair;
    address public adminAddress;

    uint256 public marketTime;

    // PancakeSwap Router地址（BSC主网）
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    AggregatorV3Interface internal bnbPriceFeed;

    uint256 public lastOpenedBlock;
    uint256 public constant MIN_OPEN_BLOCKS = 5;
    mapping(address => uint256) public lastBuyTime;
    mapping(address => uint256) public lastBuyBlock;
    uint256 public coolDownTime = 60;

    mapping(address => uint256) public lastSellBlock;

    // 状态变量
    bool public buyMarketOpen = false;  // 二级市场是否开放
    uint256 public  waitBlocks = 20;

    //twap
    uint256 public constant REQUIRED_OBSERVATIONS = 10;
    uint256[30] public poolObservations;
    uint256[30] public priceObservations;

    uint256 public poolObservationIndex;
    uint256 public priceObservationIndex;

    uint256 public lastTWAPUpdateBlock;
    uint256 public lastStablePoolValue;
    uint256 public lastStablePriceValue;
    
    uint256 public MAX_SELL_POOL_RATIO = 50;  //浮动2%
    uint256 public MAX_BUY_POOL_RATIO = 50;
    uint256 public MAX_BLOCK_PERCENT = 50;
    uint256 public MAX_DESTROY_PER_DAY = 50; //每日最大销毁2%

    uint256 public SYN_TWAP_TIME = block.timestamp;
    uint256 public lastDestroyDay;
    uint256 public destroyedToday;

    //每日限额
    uint256 public dailyLimitPercent = 10;
    uint256 public dailyLimit;
    uint256 public dailySellAmount;
    uint256 public dailyBuyAmount;
    uint256 public lastDailyReset;


    uint256 public lastBlock;
    uint256 public blockTotalBuy;
    uint256 public blockTotalSell;
    


    bool public emergencyPause = false;
    uint256 public maxBuyValueUSD = 3500 ether;
    uint256 public maxSellValueUSD = 3500 ether;
    
    
    IPancakeRouter public pancakeRouter;
    // 用户数据结构
    struct UserInfo {
        uint256 okBuyValue;      // 已经购买的额度
        uint256 allBuyValue;     //允许购买的额度
        uint256 group_rank2;
    }
    // 映射存储
    mapping(address => UserInfo) public users;
    mapping(address => bool) public isExcludedFromTax;

    //uint256[8] private DL_MIN_FEE = [3_000 ether,10_000 ether,30_000 ether,100_000 ether,300_000 ether,1_000_000 ether,3_000_000 ether,10_000_000 ether];
    uint256[9] private DL_TOTAL_FEE = [0,50 ether,200 ether,1_000 ether,2_000 ether,3_000 ether,5_000 ether,10_000 ether,20_000 ether]; // 单位：USDT (1e18 wei)
    uint256[9] private DL_TOTAL_FEE2 = [0,500 ether,1_000 ether,2_000 ether,3_000 ether,5_000 ether,5_000 ether,10_000 ether,20_000 ether];
    
    uint256 public BNB_PRICE;
    uint256 public BURN_AMOUNT;//已销毁
    uint256 public BURN_AMOUNT_PENDING;
    uint256 public AMOUNT_STOP = 2_000_000 ether;//流通阈值
    uint256 public DEL_TIME = block.timestamp;
    uint256 public DEL_TIME_SELL;
    
    // 事件
    event InteractiveContractUpdated(address indexed oldContract, address indexed newContract);
    event FounderAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event FoundationAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event AdminAddressUpdated(address indexed oldAddress, address indexed newAddress);

    event DLRecycled(uint256 amount);//OK
    event ProfitTaxDistributed(uint256 toFounder, uint256 toFoundation);//ok

    event BuyMarketStatusChanged(bool status);//ok
    event BuyRecorded(address indexed user, uint256 amount, uint256 value);

    //event Debug(address sender, address recipient, uint256 amount, string context);
    event Debug(string context,uint256 amount);

    constructor() 
        ERC20("DL TOKEN", "DL")
        Ownable(msg.sender)
    {
        
        pancakePair = IPancakeFactory(IPancakeRouter(PANCAKE_ROUTER).factory()).createPair(address(this), WBNB);
        _mint(msg.sender, TOTAL_SUPPLY);
        
        pancakeRouter = IPancakeRouter(PANCAKE_ROUTER);
        //_approve(address(this), PANCAKE_ROUTER, type(uint256).max);


        bnbPriceFeed = AggregatorV3Interface(BNB_USD_FEED);
        BNB_PRICE = getBNBPrice();
        
        isExcludedFromTax[msg.sender] = true;
        isExcludedFromTax[address(this)] = true;
        adminAddress = msg.sender;

        lastDailyReset = block.timestamp;
    }
    
    function transfer(address recipient, uint256 amount) public override  returns (bool) {
        uint256 burnAmount = 0;
        
        if (msg.sender == pancakePair || recipient == pancakePair) {
            require(!emergencyPause, "Emergency pause active");
            (amount,burnAmount) = _calculateAndProcessTax(msg.sender, recipient, amount);
        }
        bool success = super.transfer(recipient, amount);
        if(success && recipient == pancakePair){
            _checkPriceManipulation();
        }

        return success;
        //return super.transfer(recipient, amount);
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override  returns (bool) {
        uint256 burnAmount = 0;

        if (sender == pancakePair || recipient == pancakePair) {
            require(!emergencyPause, "Emergency pause active");
            (amount,burnAmount) = _calculateAndProcessTax(sender, recipient, amount);
        }
        bool success = super.transferFrom(sender, recipient, amount);
        
        if(success && recipient == pancakePair){
            _checkPriceManipulation();
        }

        return success;
        //return super.transferFrom(sender, recipient, amount);
    }
    
    function _calculateAndProcessTax(address sender, address recipient, uint256 amount) internal returns (uint256, uint256) {
        
        BNB_PRICE = getBNBPrice();
        _checkPriceManipulation(); //价格异常拦截
        _updateTWAP();
        _updateMarketStatus();
        
        bool isSell = (recipient == pancakePair);
        bool isBuy = (sender == pancakePair);
        //emit  Debug(sender, recipient, 1, "is buy==1");  && recipient != interactiveContract

        if (isSell) {
            uint256 my_sell_amount = _handleSellTransaction(sender,amount);
            return (my_sell_amount,0);

        }else if (isBuy) {
            
            uint256 my_buy_amount = _handleBuyTransaction(recipient, amount);
            return (my_buy_amount,0);
        }
        return (amount,0);
    }

    receive() external payable {}
    
    function _recordBuyValue(address user, uint256 buyAmount) internal {
        uint256 currentPrice = getCurrentPrice();
        uint256 buyValue = (buyAmount * currentPrice) / 10**18;
        users[user].okBuyValue += buyValue;
        emit BuyRecorded(user, buyAmount, buyValue);
    }

    function _checkPriceManipulation() internal view  {
        (uint256 reserveDL, uint256 reserveBNB) = getReserves();
        if (reserveDL == 0 || reserveBNB == 0) {
            return;
        }

        uint256 currentPrice = getCurrentPrice();
        if(currentPrice == 0){
            return;
        }

        uint256 dlPrice = getTWAPPrice(); //1 dl = 0.01bnb wei
        require(dlPrice > 0, "Invalid TWAP price");
        require(currentPrice <= dlPrice * 150 / 100, "Price too high vs TWAP");
        require(currentPrice >= dlPrice * 50 / 100, "Price too low vs TWAP");
    }

    function _handleBuyTransaction(address recipient, uint256 amount) internal returns (uint256) {
        
        //require(recipient.code.length == 0 || recipient == interactiveContract, "Contract address is not allowed");
        if(recipient != interactiveContract){
            require((lastBuyBlock[recipient] < block.number),"Only one buy per address per block");
            lastBuyBlock[recipient] = block.number;
        }

        // require(
        //     recipient.code.length == 0 || 
        //     recipient == interactiveContract,
        //     "Contract address is not allowed"
        // );
        //!isExcludedFromTax[recipient] && 
        if (recipient != interactiveContract) {
            require(block.timestamp >= lastBuyTime[recipient] + coolDownTime, "Please wait for cooldown");
            lastBuyTime[recipient] = block.timestamp;
        }
        
        uint256 dlPrice = getTWAPPrice(); //1 dl = 0.01bnb wei
        
        //限制大额买单
        uint256 buyValueUSD = (amount * dlPrice * BNB_PRICE) / 10**36;
        require(buyValueUSD <= maxBuyValueUSD,"amount too max");

        if(balanceOf(pancakePair) > 0){
            uint256 maxBuyAmount = balanceOf(pancakePair) / MAX_BUY_POOL_RATIO;
            require(amount <= maxBuyAmount,"amount too max");
        }
        _checkBlockLimit(amount, true);

        if(isExcludedFromTax[recipient]){
            return amount;
        }

        _resetDailyIfNeeded();
        require(dailyBuyAmount + amount <= dailyLimit, "Daily buy limit exceeded");
        dailyBuyAmount += amount;


        if(buyMarketOpen == true){
            
            users[recipient].okBuyValue += buyValueUSD;
        }else{
            //按额度

            require(buyValueUSD > 0, "Price too low"); // 防止除零或精度丢失
            (, , ,uint256 group_rank2) = IStakeContract(interactiveContract).getParentUserInfo(recipient);
            //emit  Debug(sender, recipient, group_rank2, "my user rank2 == 4");
            require(group_rank2 > 0 && group_rank2 < 9, "Insufficient quota");
            
            users[recipient].group_rank2 = group_rank2;

            uint256 index = group_rank2;

            uint256 my_amount = DL_TOTAL_FEE[index];
            if(poolValue >= MIN_POOL_VALUE2){
                my_amount = DL_TOTAL_FEE2[index];
            }
            users[recipient].allBuyValue = my_amount;
            uint256 ok_my_amount_u = my_amount > users[recipient].okBuyValue ? my_amount - users[recipient].okBuyValue : 0; //u
            require(buyValueUSD <= ok_my_amount_u,"Insufficient quota");
            
            users[recipient].okBuyValue += buyValueUSD;
            emit BuyRecorded(recipient, amount, buyValueUSD);
        }

        return amount;
    }

    function _handleSellTransaction(address sender, uint256 amount)  internal returns (uint256)  {
        
        if(sender != interactiveContract){
            require((lastSellBlock[sender] < block.number), "Only one sell per address per block");
            lastSellBlock[sender] = block.number;
        }
        
        if (!isExcludedFromTax[sender] && sender != interactiveContract) {
            require(block.timestamp >= lastBuyTime[sender] + coolDownTime, "Please wait for cooldown");
            lastBuyTime[sender] = block.timestamp;
        }

        uint256 dlPrice = getTWAPPrice(); //1 dl = 0.01bnb wei
        //限制大额卖
        
        uint256 sellValueUSD = (amount * dlPrice * BNB_PRICE) / 10**36;
        require(sellValueUSD <= maxSellValueUSD,"amount too max");
        
        if(balanceOf(pancakePair) > 0){
            uint256 maxSellAmount = balanceOf(pancakePair) / MAX_SELL_POOL_RATIO;
            require(amount <= maxSellAmount,"amount too max");
        }
        
        _checkBlockLimit(amount, false);
        
        if(isExcludedFromTax[sender]){
            return amount;
        }

        _resetDailyIfNeeded();
        require(dailySellAmount + amount <= dailyLimit, "Daily sell limit exceeded");
        dailySellAmount += amount;


        uint256 profit = amount;
        uint256 taxAmount = profit * 50 / 1000;  // 5%的总税率
        uint256 founderTax = profit * 25 / 1000;  // 2.5%转入合约，联创股东
        uint256 foundationTax = profit * 25 / 1000;  // 2.5%转入基金会
        
        if(taxAmount > 0){
            _transfer(sender, address(this), taxAmount);
        }

        if (founderTax > 0 && interactiveContract != address(0) && balanceOf(address(this)) >= founderTax) {
            _transfer(address(this), interactiveContract, founderTax);
            try IStakeContract(interactiveContract).updateFeeNodesDL(founderTax,2) {}
            catch {
                foundationTax += founderTax;
                emit Debug("updateFeeNodesDL failed", founderTax);
            }
        }

        if (foundationTax > 0 && foundationAddress != address(0) && balanceOf(address(this)) >= foundationTax) {
            _transfer(address(this), foundationAddress, foundationTax);
        }
        
        BURN_AMOUNT_PENDING += (amount - taxAmount);
        //_recycleDL(amount,BURN_ADDRESS);
        //emit ProfitTaxDistributed(founderTax, foundationTax);
        dailySellAmount -= taxAmount;
        uint256 sell_amount = amount - taxAmount;
        return sell_amount;
    }



    function getCurrentPrice() public view returns (uint256) {
        (uint256 reserveDL, uint256 reserveBNB) = getReserves();
        if (reserveDL == 0 || reserveBNB == 0) {
            return 0;
        }
        return (reserveBNB * 10**18) / reserveDL;
    }
    //获取池子厚度 U wei
    function _calculatePoolValue(uint256 bnbPriceInUSDT) private  view returns (uint256) {
        (uint256 reserveDL, uint256 reserveBNB) = getReserves();
        if (reserveDL == 0 || reserveBNB == 0) return 0;
        
        
        uint256 bnbValue = (reserveBNB * bnbPriceInUSDT) / 10**18;
        return bnbValue;    //U wei
    }
    
    function getReserves() public view returns (uint256 reserveDL, uint256 reserveBNB) {
        try IPancakePair(pancakePair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
            address token0 = IPancakePair(pancakePair).token0();
            
            if (token0 == address(this)) {
                return (uint256(reserve0), uint256(reserve1));
            } else {
                return (uint256(reserve1), uint256(reserve0));
            }
        } catch {
            return (0, 0);
        }
    }
    
    function _updateTWAP() internal {
        
        (uint256 reserveDL, uint256 reserveBNB) = getReserves();
        if (reserveDL == 0 || reserveBNB == 0) {
            return;
        }
        
        if (block.number <= lastTWAPUpdateBlock + waitBlocks) {
            return;
        }
        uint256 currentPoolValue = _calculatePoolValue(BNB_PRICE); //u wei
        _updatePoolValueTWAP(currentPoolValue);
        
        uint256 currentPrice = getCurrentPrice(); //1dl = n bnb wei
        _updatePriceTWAP(currentPrice);
        
        lastTWAPUpdateBlock =   block.number;
    }
    
    function getTWAPValue() public view returns (uint256) {
        
        uint256 sum = 0;
        uint256 count = 0;
        uint256 minPool = type(uint256).max;
        uint256 maxPool = 0;

        for (uint256 i = 0; i < 30; i++) {
            uint256 _val = poolObservations[i];
            if (_val != 0) {
                sum += _val;
                count++;

                if(_val < minPool){
                    minPool = _val;
                }
                if(_val > maxPool){
                    maxPool    =   _val;
                }
            }
        }

        if (count == 0) return _calculatePoolValue(BNB_PRICE);
        if (count >= 5) {
            sum = sum - minPool - maxPool;
            count -= 2;
        }
        return sum / count;
    }

    function getTWAPPrice() public view returns(uint256){

        if (lastTWAPUpdateBlock == 0) {
            return getCurrentPrice();
        }
    
        uint256 sum = 0;
        uint256 count = 0;
        uint256 minPrice = type(uint256).max;
        uint256 maxPrice = 0;

        for (uint256 i = 0; i < 30; i++) {
            uint256 _val = priceObservations[i];
            if (_val != 0) {
                sum += _val;
                count++;
                if(_val < minPrice){
                    minPrice = _val;
                }
                if(_val > maxPrice){
                    maxPrice    =   _val;
                }
            }
        }
        if (count == 0) return getCurrentPrice();
        if (count >= 5) {
            sum = sum - minPrice - maxPrice;
            count -= 2;
        }

        return sum / count; // bnb wei
    }

    function _updatePoolValueTWAP(uint256 currentPoolValue) private {
        
        lastStablePoolValue = currentPoolValue;
        poolValue = currentPoolValue;
        
        uint256 index = poolObservationIndex % 30;
        poolObservations[index] = currentPoolValue;
        poolObservationIndex++;
        if(poolObservationIndex > 29) poolObservationIndex = 0;
    }

    function _updatePriceTWAP(uint256 currentPrice) private {
        
        lastStablePriceValue = currentPrice;

        uint256 index = priceObservationIndex % 30;
        priceObservations[index] = currentPrice;
        priceObservationIndex++;
        if(priceObservationIndex > 29) priceObservationIndex = 0;
    }
    
    function _recycleDL(uint256 amount, address to) private {
        require(!emergencyPause, "Emergency pause active");
        if(amount > 0){
            bool beforeCheckPass = _checkDestroyPrice(10);
            if(!beforeCheckPass) {
                emit Debug("Before destroy price check failed", amount);
                return;
            }

            uint256 max_burn = balanceOf(pancakePair) / 200;
            if(amount > max_burn){
                amount = max_burn;
            }

            uint256 currentDay = block.timestamp / 1 days;
            if (currentDay != lastDestroyDay) {
                lastDestroyDay = currentDay;
                destroyedToday = 0;
            }
            uint256 maxPerDay = balanceOf(pancakePair) / MAX_DESTROY_PER_DAY; // 2%
            //require(destroyedToday + amount <= maxPerDay, "Destroy amount too large per day");

            if(destroyedToday + amount <= maxPerDay){
                //_approve(pancakePair, PANCAKE_ROUTER, amount);
                //IERC20(address(this)).approve(address(this), amount);
                super._transfer(pancakePair, to, amount);
                IPancakePair(pancakePair).sync();
                //_approve(pancakePair, PANCAKE_ROUTER, 0);
                
                bool afterCheckPass = _checkDestroyPrice(15);
                if(!afterCheckPass) {
                    //emergencyPause = true;
                    emit Debug("Destroy caused price anomaly, emergency pause triggered", 1);
                }
                
                destroyedToday += amount;
                BURN_AMOUNT += amount;
                emit DLRecycled(amount);
            }
        }
    }
    function _checkDestroyPrice(uint256 maxDeviation) internal view returns(bool) {
        (uint256 reserveDL, uint256 reserveBNB) = getReserves();
        if (reserveDL == 0 || reserveBNB == 0) return false;
        
        uint256 currentPrice = getCurrentPrice();
        uint256 twapPrice = getTWAPPrice();
        if(twapPrice == 0 || currentPrice == 0){
            return false;
        }

        uint256 maxPrice = twapPrice * (100 + maxDeviation) / 100;
        uint256 minPrice = twapPrice * (100 - maxDeviation) / 100;
        
        if(currentPrice > maxPrice || currentPrice < minPrice){
            return false;
        }

        return true;
    }
    function delDl() external nonReentrant {
        require(msg.sender == interactiveContract || msg.sender == adminAddress,"no permission");
        (uint256 reserveDL,) = getReserves();
        //uint256 reserveDL = balanceOf(address(this));
        if(reserveDL > AMOUNT_STOP){
            uint256 del_day = (block.timestamp - DEL_TIME)/ 1 days;
            if(del_day > 0){
                uint256 amount_off = (reserveDL * 5)/1000;
                if(amount_off > 0){
                    DEL_TIME = block.timestamp;
                    //BURN_AMOUNT += amount_off;
                    emit Debug("del amount",amount_off);
                    _recycleDL(amount_off, BURN_ADDRESS);
                }
            }
        }
        if(BURN_AMOUNT_PENDING > 0 && (block.timestamp - DEL_TIME_SELL) >  300){
            uint256 amount_off = BURN_AMOUNT_PENDING * 5 / 100;
            if(amount_off > balanceOf(pancakePair) / 100){
                amount_off = balanceOf(pancakePair) / 100;
            }
            emit Debug("del BURN_AMOUNT_PENDING",amount_off);
            _recycleDL(amount_off, BURN_ADDRESS);
            BURN_AMOUNT_PENDING -= amount_off;
            DEL_TIME_SELL = block.timestamp;
        }
    }
    
    function getBNBPrice() public view  returns (uint256) {
        try bnbPriceFeed.latestRoundData() returns (
            uint80 roundID,
            int256 price,
            uint256,
            uint256 timeStamp,
            uint80 answeredInRound
        ) {
            
            bool isPriceValid = price > 0 && timeStamp > (block.timestamp - 3600) && answeredInRound >= roundID;
            if (isPriceValid) {
                uint256 bnbPriceUSD = uint256(price) * 10**10;
                
                if (BNB_PRICE == 0) {
                    return bnbPriceUSD;
                }
                if (bnbPriceUSD > BNB_PRICE * 150 / 100) {
                    return BNB_PRICE * 150 / 100;
                } else if (bnbPriceUSD < BNB_PRICE * 50 / 100) {
                    return BNB_PRICE * 50 / 100;
                } else {
                    return bnbPriceUSD;
                }
            }
        } catch {
            
        }

        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = USDT;
        
        try IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(10**18, path) returns (uint256[] memory amounts) {
            if (amounts.length >= 2 && amounts[1] > 0) {
                return amounts[1];
            }
        } catch {}
        
        return BNB_PRICE;
    }
    
    function _updateMarketStatus() private  {
        //poolValue = _calculatePoolValue(BNB_PRICE);
        poolValue = getTWAPValue();
        if(MAX_POOL_VALUE == 0){
            MAX_POOL_VALUE  =   poolValue;
            return;
        }

        if(poolValue > MAX_POOL_VALUE * 15/10){
            MAX_POOL_VALUE = poolValue * 15 / 10;
        }else if(poolValue > MAX_POOL_VALUE){
            MAX_POOL_VALUE = poolValue;
        }
        
        
        bool isCurrentlyQualified = false;
        if(poolValue >= MIN_POOL_VALUE){
            isCurrentlyQualified = true;
        } else if (MAX_POOL_VALUE >= MIN_POOL_VALUE && poolValue >= MIN_POOL_VALUE2){
            isCurrentlyQualified = true;
        }

        if (isCurrentlyQualified) {
            if (lastOpenedBlock == 0) {
                lastOpenedBlock = block.number;
            }
            if (block.number >= lastOpenedBlock + waitBlocks) {
                if (!buyMarketOpen) {
                    buyMarketOpen = true;
                    emit BuyMarketStatusChanged(true);
                }
            }
        } else {
            lastOpenedBlock = 0;
            if (buyMarketOpen) {
                buyMarketOpen = false;
                emit BuyMarketStatusChanged(false);
            }
        }
    }

    function _resetDailyIfNeeded() private {
        if (block.timestamp >= lastDailyReset + 1 days) {
            dailySellAmount = 0;
            dailyBuyAmount = 0;
            lastDailyReset = block.timestamp;
            
            uint256 poolBalance = balanceOf(pancakePair);
            dailyLimit = (poolBalance * dailyLimitPercent) / 100;
        }
    }
    function _checkBlockLimit(uint256 amount, bool isBuy) internal {
        if (block.number != lastBlock) {
            lastBlock = block.number;
            blockTotalBuy = 0;
            blockTotalSell = 0;
        }

        uint256 poolBal = balanceOf(pancakePair);
        uint256 maxAmount = poolBal / MAX_BLOCK_PERCENT;

        if (isBuy) {
            blockTotalBuy += amount;
            require(blockTotalBuy <= maxAmount, "Block buy overflow");
        } else {
            blockTotalSell += amount;
            require(blockTotalSell <= maxAmount, "Block sell overflow");
        }
    }
    //=========
    function setInteractiveContract(address _op) external  {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldContract = interactiveContract;
        interactiveContract = _op;

        isExcludedFromTax[oldContract] = false;
        isExcludedFromTax[_op] = true;
        emit InteractiveContractUpdated(oldContract, _op);
    }
    function setFoundationAddress(address _op) external  {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldAddress = foundationAddress;
        foundationAddress = _op;
        
        isExcludedFromTax[oldAddress] = false;
        isExcludedFromTax[_op] = true;

        emit FoundationAddressUpdated(oldAddress, _op);
    }
    
    function setExcludedFromTax(address _op, bool excluded) external {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        isExcludedFromTax[_op] = excluded;
        emit Debug("setExcludedFromTax", excluded ? 1 : 0);
    }

    function setCoolDownTime(uint256 _time) external {
        require(msg.sender == adminAddress || msg.sender == owner(), "no permission");
        require(_time >= 0 && _time <= 3600, "Cooldown out of range (0-3600)");
        coolDownTime = _time;
        emit Debug("setCoolDownTime", _time);
    }

    function setMaxValueForMarket(uint256 _amount,uint256 _type) external {
        require(msg.sender == adminAddress || msg.sender == owner(), "no permission");
        require(_amount > 0, "Amount must be positive");
        if(_type == 1){
            maxBuyValueUSD = _amount;
            emit Debug("setMaxBuyValueUSD", _amount);
        }else if(_type == 2){
            maxSellValueUSD = _amount;
            emit Debug("setMaxSellValueUSD", _amount);
        }else if(_type == 3){
            require(_amount >= 2, "MAX_BUY_POOL_RATIO too small");
            MAX_BUY_POOL_RATIO =   _amount;
            emit Debug("MAX_BUY_POOL_RATIO", _amount);
        }else if(_type == 4){
            require(_amount >= 2, "MAX_SELL_POOL_RATIO too small");
            MAX_SELL_POOL_RATIO =   _amount;
            emit Debug("MAX_SELL_POOL_RATIO", _amount);
        }else if(_type == 5){
            require(_amount > 0 && _amount <= 100, "Percent must be between 1 and 100");
            dailyLimitPercent =   _amount;
            uint256 poolBalance = balanceOf(pancakePair);
            dailyLimit = (poolBalance * dailyLimitPercent) / 100;

            emit Debug("dailyLimitPercent", _amount);
        }else if(_type == 6){
            
            dailySellAmount = 0;
            dailyBuyAmount = 0;
            lastDailyReset = block.timestamp;
            
            uint256 poolBalance = balanceOf(pancakePair);
            dailyLimit = (poolBalance * dailyLimitPercent) / 100;
            
            emit Debug("_resetDailyIfNeeded", _amount);
        }else if(_type == 7){
            require(_amount >= 2, "MAX_BLOCK_PERCENT too small");
            MAX_BLOCK_PERCENT =   _amount;
            emit Debug("MAX_BLOCK_PERCENT", _amount);
        }else if(_type == 8){
            require(_amount >= 2, "MAX_DESTROY_PER_DAY too small");
            MAX_DESTROY_PER_DAY =   _amount;
            emit Debug("MAX_DESTROY_PER_DAY", _amount);
        }
    }

    function setAmountStop(uint256 _amount) external{
        require(msg.sender == owner() || msg.sender == adminAddress,"no permission");
        require(_amount > 0,"amount is wrong");
        AMOUNT_STOP = _amount;

        emit Debug("setAmountStop",AMOUNT_STOP);
    }

    function setAdminAddress(address _op) external  onlyOwner{
        //require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldAddress = adminAddress;
        adminAddress = _op;
        
        isExcludedFromTax[oldAddress] = false;
        isExcludedFromTax[_op] = true;

        emit AdminAddressUpdated(oldAddress, _op);
    }
    
    

    function setWaitBlocks(uint256 _waitBlocks) external  {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_waitBlocks > 0, "Wait blocks must be positive");
        waitBlocks = _waitBlocks;

        emit Debug("setWaitBlocks",waitBlocks);
    }

    function setPancakePair(address _op) external onlyOwner {
        require(_op != address(0), "Cannot set to zero address");

        pancakePair = _op;
        
        emit Debug("setPancakePair",1);
    }

    function synMaxPoolValue(uint256 _val) external {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        if(_val > 0){
            MAX_POOL_VALUE = _val;
            emit Debug("synMaxPoolValue",_val);
        }else{
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = USDT;
            
            try IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(10**18, path) returns (uint256[] memory amounts) {
                BNB_PRICE =  amounts[1];
            } catch {
                BNB_PRICE =  BNB_PRICE;
            }
            emit Debug("poolValue",BNB_PRICE);
            poolValue = _calculatePoolValue(BNB_PRICE);
            lastStablePoolValue = poolValue;
            _updateTWAP();
            if(poolValue > MAX_POOL_VALUE){
                MAX_POOL_VALUE = poolValue;
            }
            emit Debug("poolValue",poolValue);
        }
    }

    //外部定期更新价格
    function synTWAP() external  {
        if(block.timestamp > (SYN_TWAP_TIME + 300)){
            _updateTWAP();
            SYN_TWAP_TIME = block.timestamp;
        }
    }
    function getTWAP(uint256 _val) external view returns (uint256) {
        if(_val == 1){
            return getTWAPValue();
        }else if(_val == 2){
            return getTWAPPrice();
        }
        return 0;
    }
    function setEmergencyPause(bool _pause) external {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        emergencyPause = _pause;
        uint256 _debug_amount;
        if(_pause){
            _debug_amount   =   1;
        }else{
            _debug_amount   =   0;
        }
        emit Debug("setEmergencyPause",_debug_amount);
    }

    function getUserInfo(address user) external view returns (uint256 allBuyValue, uint256 rank) {

        (, , ,uint256 group_rank2) = IStakeContract(interactiveContract).getParentUserInfo(user);
        uint256 fee = group_rank2 > 0 ? DL_TOTAL_FEE[group_rank2] :0;
        return (fee,group_rank2);
    }
}
