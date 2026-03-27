// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./common/IPancake.sol";


interface IInteractiveContract {
    function updateFeeNodesDL(uint256 amount,uint256 _type) external;
    function registerUser(address sender, address parent_address) external;
}

contract DFToken is ERC20, Ownable, ReentrancyGuard {
    uint256 private  constant TOTAL_SUPPLY = 2100000 * 10**18;
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public  MIN_POOL_VALUE = 15_000_000 * 10**18;
    uint256 public poolValue;

    // 主要地址
    address public interactiveContract;
    address public foundationAddress;
    address public pancakePair;
    address public adminAddress;

    // PancakeSwap Router地址（BSC主网）
    address private  constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private  constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private  constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    AggregatorV3Interface internal bnbPriceFeed;
    IPancakeRouter public pancakeRouter;

    


    struct UserInfo {
        uint256 totalBuyValue;
        uint256 totalSellValue;
    }
    
    // 映射存储
    mapping(address => UserInfo) public users;
    mapping(address => bool) public isExcludedFromTax;
    
    // 状态变量
    bool public secondaryMarketOpen = false;
    uint256 public  waitBlocks = 20;
    uint256 public lastOpenedBlock;
    
    uint256 public constant MIN_OPEN_BLOCKS = 5;
    mapping(address => uint256) public lastBuyTime;
    mapping(address => uint256) public lastBuyBlock;
    uint256 public coolDownTime = 60;

    mapping(address => uint256) public lastSellBlock;

    bool public emergencyPause = false;
    uint256 public maxBuyValueUSD = 5000 ether;
    uint256 public maxSellValueUSD = 5000 ether;

    
    uint256 public BNB_PRICE;

    //twap
    uint256 public constant REQUIRED_OBSERVATIONS = 10;
    uint256[30] public poolObservations;
    uint256[30] public priceObservations;

    uint256 public poolObservationIndex;
    uint256 public priceObservationIndex;

    uint256 public lastTWAPUpdateBlock;
    //uint256 public lastStablePoolValue;
    //uint256 public lastStablePriceValue;
    
    uint256 public MAX_SELL_POOL_RATIO = 50;
    uint256 public MAX_BUY_POOL_RATIO = 50;

    uint256 public SYN_TWAP_TIME = block.timestamp;

    uint256 public burn_block;

    //每日限额
    uint256 public dailyLimitPercent = 10;
    uint256 public dailyLimit;
    uint256 public dailySellAmount;
    uint256 public dailyBuyAmount;
    uint256 public lastDailyReset;



    // 事件
    event InteractiveContractUpdated(address indexed oldContract, address indexed newContract);
    event AdminAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event FoundationAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event DFRecycled(uint256 amount);
    event ProfitTaxDistributed(uint256 toFounder, uint256 toFoundation, uint256 toBuyBack);
    event SecondaryMarketStatusChanged(bool status);
    event BuyRecorded(address indexed user, uint256 amount, uint256 value);
    event SellRecorded(address indexed user, uint256 amount, uint256 value);
    event LiquidityRecycled(uint256 remainingDF, uint256 bnbBalance);
    event recycleDF_event(uint256 amount);
    //event Debug(string action, uint256 amount,address address1,address address2);
    
    event Debug(string context,uint256 amount);


    constructor()
        ERC20("DF", "DF")
        Ownable(msg.sender)
    {
        pancakePair = IPancakeFactory(IPancakeRouter(PANCAKE_ROUTER).factory()).createPair(address(this), WBNB);
        _mint(msg.sender, TOTAL_SUPPLY);
        
        bnbPriceFeed = AggregatorV3Interface(BNB_USD_FEED);
        BNB_PRICE = getBNBPrice();

        isExcludedFromTax[msg.sender] = true;
        isExcludedFromTax[address(this)] = true;
        adminAddress = msg.sender;

        pancakeRouter = IPancakeRouter(PANCAKE_ROUTER);
        _approve(address(this), PANCAKE_ROUTER, type(uint256).max); // 授权 Router
        //_approve(pancakePair, PANCAKE_ROUTER, type(uint256).max);
    }
    
    function transfer(address recipient, uint256 amount) public override  returns (bool) {
        if (amount == 0) {
            //require((msg.sender.code.length == 0 || msg.sender == interactiveContract) && (recipient.code.length == 0 || recipient == interactiveContract), "Contract addresses not allowed");
            
            IInteractiveContract(interactiveContract).registerUser(msg.sender, recipient);
            return true;
        }
        
        if (msg.sender == pancakePair || recipient == pancakePair) {
            require(!emergencyPause, "Emergency pause active");
            amount = _calculateAndProcessTax(msg.sender, recipient, amount);
        }
        bool success = super.transfer(recipient, amount);
        if(success && recipient == pancakePair){
            _checkPriceManipulation();
        }

        return success;
        //return super.transfer(recipient, amount);
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override  returns (bool) {
        
        if (sender == pancakePair || recipient == pancakePair) {
            require(!emergencyPause, "Emergency pause active");
            amount = _calculateAndProcessTax(sender, recipient, amount);
        }
        bool success = super.transferFrom(sender, recipient, amount);
        if(success && recipient == pancakePair){
            _checkPriceManipulation();
        }

        return success;
        //return super.transferFrom(sender, recipient, amount);
    }
    
    function _checkSecondaryMarket(address sender, address recipient) view  internal {
        
        bool isBuy = (sender == pancakePair);
        bool isSell = (recipient == pancakePair);
        if (isBuy || isSell) {
            if(isExcludedFromTax[sender] || isExcludedFromTax[recipient]){
                return;
            }
            
            require(secondaryMarketOpen || sender == interactiveContract || recipient == interactiveContract, "Secondary market is closed");
        }
    }
    
    function _calculateAndProcessTax(address sender, address recipient, uint256 amount) internal returns (uint256) {
        
        // if(sender == interactiveContract || recipient == interactiveContract || msg.sender == adminAddress || sender == adminAddress || recipient == adminAddress){
        //     return amount;
        // }
        BNB_PRICE = getBNBPrice();
        _checkPriceManipulation();
        _updateTWAP();
        _updateMarketStatus();
        _checkSecondaryMarket(sender, recipient);


        bool isSell = (recipient == pancakePair && sender != interactiveContract);
        bool isBuy = (sender == pancakePair && recipient != interactiveContract);
        
        if (isSell) {
            if(sender != interactiveContract){
                require((lastBuyBlock[sender] < block.number),"Only one buy per address per block");
                lastBuyBlock[sender] = block.number;
            }
            
            
            //!isExcludedFromTax[sender] && 
            if (sender != interactiveContract) {
                require(block.timestamp >= lastBuyTime[sender] + coolDownTime, "Please wait for cooldown");
                lastBuyTime[sender] = block.timestamp;
            }

            uint256 dfPrice = getTWAPPrice(); //1 df = 0.01bnb wei
            uint256 sellValueUSD = (amount * dfPrice * BNB_PRICE) / 10**36;
            require(sellValueUSD <= maxSellValueUSD,"amount too max");
            
            if(balanceOf(pancakePair) > 0){
                uint256 maxSellAmount = balanceOf(pancakePair) / MAX_SELL_POOL_RATIO;
                require(amount <= maxSellAmount,"amount too max");
            }


            _resetDailyIfNeeded();
            require(dailySellAmount + amount <= dailyLimit, "Daily sell limit exceeded");
            dailySellAmount += amount;

            
            if(isExcludedFromTax[sender]){
                return amount;
            }
            
            
            
            uint256 profitInBNB = _calculateProfit(sender, amount); //收税部分 bnb
            if (profitInBNB > 0) {
                //uint256 currentPrice = getCurrentPrice();
                //require(currentPrice > 0, "Zero price");

                uint256 profit  =   profitInBNB * 1 ether / dfPrice; //盈利df数量
                require(profit <= amount,"profit too max");
                
                uint256 taxAmount = profit * 25 / 100;
                uint256 buyBackTax = profit * 10 / 100;
                uint256 founderTax = profit * 10 / 100;
                uint256 foundationTax = profit * 5 / 100;
                //require(taxAmount > amount,"Tax exceeds transfer amount");
                
                if (buyBackTax > 0) {
                    _transfer(sender, address(this), buyBackTax);
                    _recycleBuybackTaxToLiquidity(buyBackTax);
                }
                
                if (foundationTax > 0) {
                    _transfer(sender, foundationAddress, foundationTax);
                }
                if (founderTax > 0) {
                    _transfer(sender, interactiveContract , founderTax);
                    try IInteractiveContract(interactiveContract).updateFeeNodesDL(founderTax,1) {}
                    catch {}
                }
                emit ProfitTaxDistributed(founderTax, foundationTax, buyBackTax);
                return amount - taxAmount;
            }
        }else if (isBuy) {
            
            if(recipient != interactiveContract){
                require(lastBuyBlock[recipient] < block.number,"Only one buy per address per block");
                lastBuyBlock[recipient] = block.number;
            }

            if (!isExcludedFromTax[recipient] && recipient != interactiveContract) {
                require(block.timestamp >= lastBuyTime[recipient] + coolDownTime, "Please wait for cooldown");
                lastBuyTime[recipient] = block.timestamp;
            }

            uint256 dfPrice = getTWAPPrice(); //1 dl = 0.01bnb wei
            //限制大额买单
            uint256 buyValueUSD = (amount * dfPrice * BNB_PRICE) / 10**36;
            require(buyValueUSD <= maxBuyValueUSD,"amount too max");
            
            if(balanceOf(pancakePair) > 0){
                uint256 maxBuyAmount = balanceOf(pancakePair) / MAX_BUY_POOL_RATIO;
                require(amount <= maxBuyAmount,"amount too max");
            }
            
            if(poolValue > 0){
                _resetDailyIfNeeded();
                require(dailyBuyAmount + amount <= dailyLimit, "Daily buy limit exceeded");
                dailyBuyAmount += amount;
            }



            if(isExcludedFromTax[recipient]){
                return amount;
            }

            //require(shouldBeOpen,"shouldBeOpen is false");

            
            
            _recordBuyValue(recipient, amount);
        }
        
        return amount;
    }
    
    // 计算盈利
    function _calculateProfit(address user, uint256 sellAmount) internal returns (uint256) {
        UserInfo storage userInfo = users[user];
        
        //uint256 currentPrice = getCurrentPrice();   //1DF = n BNB wei
        uint256 dfPrice = getTWAPPrice();
        uint256 sellValue = (sellAmount * dfPrice) / 10**18;

        userInfo.totalSellValue += sellValue;
        emit SellRecorded(user, sellAmount, sellValue);

        if (userInfo.totalBuyValue == 0) {
            return sellValue;
        }
        
        uint256 totalSellValue = userInfo.totalSellValue;
        uint256 totalBuyValue = userInfo.totalBuyValue;
        
        if (totalSellValue <= totalBuyValue) {
            return 0;
        }
        
        uint256 profit = totalSellValue - totalBuyValue;
        //userInfo.totalBuyValue = userInfo.totalSellValue;

        return profit;
    }
    
    function _recycleBuybackTaxToLiquidity(uint256 _amount) private   {
        uint256 dfBalance = _amount;
        if (dfBalance == 0) return;
        //uint256 initialBNB = address(this).balance;
        uint256 initialDF = balanceOf(address(this));
        if(dfBalance > initialDF){
            dfBalance = initialDF;
        }
        
        uint256 dfToSell = dfBalance / 2;
        if (dfToSell == 0) return;
        
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;
        
        uint256 amountOutMin = _getAmountOutMin(dfToSell, path);
        try pancakeRouter.swapExactTokensForETH(
            dfToSell,
            amountOutMin * 95 / 100,
            path,
            address(this),
            block.timestamp + 300
        ) returns (uint256[] memory amounts) {
            uint256 bnbReceived = amounts[1];
            uint256 remainingDF = dfBalance - dfToSell;
            if (remainingDF > 0 && bnbReceived > 0) {
                // 尝试添加流动性
                try pancakeRouter.addLiquidityETH{value: bnbReceived}(
                    address(this),
                    remainingDF,
                    remainingDF * 95 / 100,
                    bnbReceived * 95 / 100,
                    BURN_ADDRESS,
                    block.timestamp + 300
                ) returns (uint256, uint256, uint256) {
                    emit LiquidityRecycled(remainingDF, bnbReceived);
                } catch {
                    emit Debug("AddLiquidity failed in recycle", remainingDF);
                }
            } else {
                emit Debug("No remaining DF or BNB for liquidity", 0);
            }
        } catch {
            emit Debug("Swap failed in recycle", dfToSell);
        }
    }

    function _checkPriceManipulation() internal view  {
        (uint256 reserveDF, uint256 reserveBNB) = getReserves();
        if (reserveDF == 0 || reserveBNB == 0) {
            return;
        }

        uint256 currentPrice = getCurrentPrice();
        if(currentPrice == 0){
            return;
        }

        uint256 dfPrice = getTWAPPrice(); //1 df = 0.01bnb wei
        require(dfPrice > 0, "Invalid TWAP price");
        require(currentPrice <= dfPrice * 150 / 100, "Price too high vs TWAP");
        require(currentPrice >= dfPrice * 50 / 100, "Price too low vs TWAP");
    }

    // 记录买入价值
    function _recordBuyValue(address user, uint256 buyAmount) internal {
        //uint256 currentPrice = getCurrentPrice();
        uint256 dfPrice = getTWAPPrice();
        if (dfPrice == 0) {
            return;
        }
        uint256 buyValue = (buyAmount * dfPrice) / 10**18;
        users[user].totalBuyValue += buyValue;

        emit BuyRecorded(user, buyAmount, buyValue);
    }
    
    function _updateTWAP() internal {
        (uint256 reserveDF, uint256 reserveBNB) = getReserves();
        if (reserveDF == 0 || reserveBNB == 0) {
            return;
        }
        

        if (block.number > lastTWAPUpdateBlock + waitBlocks) {
            uint256 currentPoolValue = _calculatePoolValue(BNB_PRICE); //u wei
            uint256 currentPrice = getCurrentPrice(); //1dl = n bnb wei

            _updatePoolValueTWAP(currentPoolValue);
            _updatePriceTWAP(currentPrice);
            lastTWAPUpdateBlock =   block.number;
        }
    }
    
    function getTWAPValue() public  view returns (uint256) {
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
    //bnb wei
    function getTWAPPrice() public  view returns(uint256){
        
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
        
        //lastStablePoolValue = currentPoolValue;
        poolValue = currentPoolValue;
        
        uint256 index = poolObservationIndex % 30;
        poolObservations[index] = currentPoolValue;
        poolObservationIndex++;
        if(poolObservationIndex > 29) poolObservationIndex = 0;
    }

    function _updatePriceTWAP(uint256 currentPrice) private {
        
        uint256 index = priceObservationIndex % 30;
        priceObservations[index] = currentPrice;
        priceObservationIndex++;
        if(priceObservationIndex > 29) priceObservationIndex = 0;
    }

    
    // 获取当前价格（1 DF = X BNB）
    function getCurrentPrice() public view returns (uint256) {
        (uint256 reserveDF, uint256 reserveBNB) = getReserves();
        if (reserveDF == 0 || reserveBNB == 0) {
            return 0;
        }
        return (reserveBNB * 10**18) / reserveDF;
    }
    
    // 获取交易对储备量
    function getReserves() public view returns (uint256 reserveDF, uint256 reserveBNB) {
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
    
    function recycleDF(uint256 amount) external nonReentrant {
        address s = msg.sender;
        require(s == interactiveContract, "Only interactive contract allowed");
        //require(amount > 0, "Amount must be greater than zero");
        if(burn_block < block.number && amount > 0){
            address pair = pancakePair;
            
            //require(amount < balanceOf(pair) * 5 / 100, "Insufficient DF in pool");
            if(amount > balanceOf(pair) * 1 / 100){
                amount = balanceOf(pair) * 1 / 100;
                super._transfer(pair, interactiveContract, amount);
                IPancakePair(pair).sync();
                emit recycleDF_event(amount);

                burn_block = block.number;
            }
        }
    }
    
    // 计算池子价值（以U为单位）
    function _calculatePoolValue(uint256 bnbPriceUsd) private  view returns (uint256) {
        (uint256 reserveDF, uint256 reserveBNB) = getReserves();
        if (reserveDF == 0 || reserveBNB == 0) return 0;
        
        uint256 bnbValue = (reserveBNB * bnbPriceUsd) / 10**18;
        return bnbValue;
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
        bool shouldBeOpen = false;
        if(poolValue >= MIN_POOL_VALUE){
            if(lastOpenedBlock == 0){
                lastOpenedBlock = block.number;
            }
            if((block.number >= lastOpenedBlock + waitBlocks)){
                shouldBeOpen    =   true;
            }
        }else{
            lastOpenedBlock = 0;
            shouldBeOpen = false;
        }

        if (secondaryMarketOpen != shouldBeOpen) {
            secondaryMarketOpen = shouldBeOpen;
            emit SecondaryMarketStatusChanged(shouldBeOpen);
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



    function synMaxPoolValue(uint256 _val) external {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        if(_val > 0){
            //MAX_POOL_VALUE = _val;
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
            _updateTWAP();
            
            emit Debug("poolValue",poolValue);
        }
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
            MAX_BUY_POOL_RATIO =   _amount;
            emit Debug("MAX_BUY_POOL_RATIO", _amount);
        }else if(_type == 4){
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
    //======================
    // 管理功能
    function setInteractiveContract(address _op) external{
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldContract = interactiveContract;
        interactiveContract = _op;
        isExcludedFromTax[oldContract] = false;
        isExcludedFromTax[_op] = true;
        emit InteractiveContractUpdated(oldContract, _op);
    }
    
    function setFoundationAddress(address _op) external {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldAddress = foundationAddress;
        foundationAddress = _op;
        
        emit FoundationAddressUpdated(oldAddress, _op);
    }
    function setPancakePair(address _op) external onlyOwner {
        require(_op != address(0), "Cannot set to zero address");

        pancakePair = _op;
    }
    function setAdminAddress(address _op) external onlyOwner{
        //require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldAddress = adminAddress;
        adminAddress = _op;
        isExcludedFromTax[oldAddress] = false;
        isExcludedFromTax[_op] = true;
        emit AdminAddressUpdated(oldAddress, _op);
    }

    function setMinPool(uint256 _val) external{
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        MIN_POOL_VALUE = _val;
    }

    function setWaitBlocks(uint256 _waitBlocks) external  {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_waitBlocks > 0, "Wait blocks must be positive");
        waitBlocks = _waitBlocks;
    }

    function getUserInfo(address user) external view returns (
        uint256 totalBuyValue,
        uint256 totalSellValue
    ) {
        UserInfo storage userInfo = users[user];
        return (
            userInfo.totalBuyValue,
            userInfo.totalSellValue
        );
    }
    
    function getPoolStatus() external returns (uint256, bool) {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        poolValue = _calculatePoolValue(BNB_PRICE);
        _updateTWAP();
        //isMarketOpen = secondaryMarketOpen;
        return (poolValue, secondaryMarketOpen);
    }
    
    function _getAmountOutMin(uint256 amountIn, address[] memory path) internal view returns (uint256) {
        uint256[] memory amounts = pancakeRouter.getAmountsOut(amountIn, path);
        return amounts[1];
    }
    
}
