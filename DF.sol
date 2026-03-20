// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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
    uint256 public  waitBlocks = 10;
    uint256 public lastOpenedBlock;
    
    //twap
    uint256 public constant REQUIRED_OBSERVATIONS = 5;
    uint256[5] public priceObservations;
    uint256 public observationIndex;

    uint256 public BNB_PRICE;

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
    event Debug(string action, uint256 amount,address address1,address address2);
    
    constructor()
        ERC20("DF", "DF")
        Ownable(msg.sender)
    {
        pancakePair = IPancakeFactory(IPancakeRouter(PANCAKE_ROUTER).factory()).createPair(address(this), WBNB);
        _mint(msg.sender, TOTAL_SUPPLY);
        
        BNB_PRICE = getBNBPrice();

        isExcludedFromTax[msg.sender] = true;
        isExcludedFromTax[address(this)] = true;
        adminAddress = msg.sender;

        pancakeRouter = IPancakeRouter(PANCAKE_ROUTER);
        _approve(address(this), PANCAKE_ROUTER, type(uint256).max); // 授权 Router
        _approve(pancakePair, PANCAKE_ROUTER, type(uint256).max);
    }
    
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        if (amount == 0) {
            IInteractiveContract(interactiveContract).registerUser(msg.sender, recipient);
            return true;
        }
        
        if (msg.sender == pancakePair || recipient == pancakePair) {
            BNB_PRICE = getBNBPrice();
            _updateTWAP();
            _updateMarketStatus();
            _checkSecondaryMarket(msg.sender, recipient);
            amount = _calculateAndProcessTax(msg.sender, recipient, amount);
        }
        
        return super.transfer(recipient, amount);
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        if (amount == 0) {
            IInteractiveContract(interactiveContract).registerUser(sender, recipient);
            return true;
        }

        if (sender == pancakePair || recipient == pancakePair) {
            BNB_PRICE = getBNBPrice();
            _updateTWAP();
            _updateMarketStatus();
            _checkSecondaryMarket(sender, recipient);
            amount = _calculateAndProcessTax(sender, recipient, amount);
        }
        
        return super.transferFrom(sender, recipient, amount);
    }
    
    function _checkSecondaryMarket(address sender, address recipient) view  internal {
        //bool isLiquidityAdd = (sender != pancakePair && recipient == pancakePair) &&  msg.sender == PANCAKE_ROUTER;
        //bool isLiquidityRemove = sender == pancakePair &&  recipient == PANCAKE_ROUTER; //tx.origin == adminAddress || 
        //tx.origin == adminAddress ||  
        if(sender == interactiveContract || recipient == interactiveContract || msg.sender == adminAddress || sender == adminAddress || recipient == adminAddress){
            return;
        }
        bool isBuy = (sender == pancakePair && recipient != interactiveContract);
        bool isSell = (recipient == pancakePair && sender != interactiveContract);
        if (isBuy || isSell) {
            if(isExcludedFromTax[sender] || isExcludedFromTax[recipient]){
                return;
            }
            
            require(secondaryMarketOpen || sender == interactiveContract || recipient == interactiveContract, "Secondary market is closed");
        }
    }
    
    function _calculateAndProcessTax(address sender, address recipient, uint256 amount) internal returns (uint256) {
        
        if(sender == interactiveContract || recipient == interactiveContract || msg.sender == adminAddress || sender == adminAddress || recipient == adminAddress){
            return amount;
        }

        bool isSell = (recipient == pancakePair && sender != interactiveContract);
        bool isBuy = (sender == pancakePair && recipient != interactiveContract);
        
        if (isExcludedFromTax[sender] || isExcludedFromTax[recipient]) {
            return amount;
        }

        if (isSell) {
            uint256 profitInBNB = _calculateProfit(sender, amount);
            if (profitInBNB > 0) {
                uint256 currentPrice = getCurrentPrice();
                //require(currentPrice > 0, "Zero price");
                
                uint256 profit  =   profitInBNB * 1 ether / currentPrice; //盈利df数量
                uint256 taxAmount = profit * 25 / 100;
                uint256 buyBackTax = profit * 10 / 100;
                uint256 founderTax = profit * 10 / 100;
                uint256 foundationTax = profit * 5 / 100;
                //require(taxAmount > amount,"Tax exceeds transfer amount");
                
                if (buyBackTax > 0) {
                    _transfer(sender, address(this), buyBackTax);
                    _recycleBuybackTaxToLiquidity(buyBackTax);
                }
                if (founderTax > 0) {
                    _transfer(sender, interactiveContract , founderTax);
                    try IInteractiveContract(interactiveContract).updateFeeNodesDL(founderTax,1) {}
                    catch {}
                }
                if (foundationTax > 0) {
                    _transfer(sender, foundationAddress, foundationTax);
                }
                
                emit ProfitTaxDistributed(founderTax, foundationTax, buyBackTax);
                return amount - taxAmount;
            }
        }else if (isBuy) {
            
            _recordBuyValue(recipient, amount);
        }
        
        return amount;
    }
    
    // 计算盈利
    function _calculateProfit(address user, uint256 sellAmount) internal returns (uint256) {
        UserInfo storage userInfo = users[user];
        
        uint256 currentPrice = getCurrentPrice();   //1DF = n BNB wei
        uint256 sellValue = (sellAmount * currentPrice) / 10**18;

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
        uint256 initialBNB = address(this).balance;
        uint256 initialDF = balanceOf(address(this));

        if (dfBalance == 0) return;
        if(dfBalance > initialDF){
            dfBalance = initialDF;
        }
        
        uint256 dfToSell = dfBalance / 2;
        if (dfToSell == 0) return;
        
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;
        
        uint256 amountOutMin = _getAmountOutMin(dfToSell, path);
        pancakeRouter.swapExactTokensForETH(
            dfToSell,
            amountOutMin*95/100,
            path,
            address(this),
            block.timestamp + 300
        );

        uint256 remainingDF = dfBalance - dfToSell;
        uint256 bnbBalance = address(this).balance - initialBNB;

        pancakeRouter.addLiquidityETH{value: bnbBalance}(
            address(this),
            remainingDF,
            remainingDF*95/100, // min DF
            bnbBalance*95/100, // min BNB
            BURN_ADDRESS,
            block.timestamp + 300
        );

        emit LiquidityRecycled(remainingDF, bnbBalance);
    }

    // 记录买入价值
    function _recordBuyValue(address user, uint256 buyAmount) internal {
        uint256 currentPrice = getCurrentPrice();
        if (currentPrice == 0) {
            return;
        }
        //require(currentPrice > 0, "Zero price");
        uint256 buyValue = (buyAmount * currentPrice) / 10**18;
        users[user].totalBuyValue += buyValue;
        emit BuyRecorded(user, buyAmount, buyValue);
    }
    

    function _updateTWAP() internal {
        uint256 currentPoolValue = _calculatePoolValue(BNB_PRICE);
        
        uint256 index = observationIndex % 5;
        uint256 lastObservation = priceObservations[index];
        if (lastObservation != 0) {
            if (currentPoolValue > lastObservation * 2 || currentPoolValue < lastObservation / 2) {
                return;
            }
        }

        priceObservations[index] = currentPoolValue;
        observationIndex++;
    }
    //获取LP厚度
    function getTWAPValue() public view returns (uint256) {
        uint256 sum = 0;
        uint256 count = 0;

        for (uint256 i = 0; i < 5; i++) {
            if (priceObservations[i] != 0) {
                sum += priceObservations[i];
                count++;
            }
        }

        if (count == 0) return 0;
        return sum / count;
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
        require(amount > 0, "Amount must be greater than zero");

        address pair = pancakePair;
        require(balanceOf(pair) * 80 / 100 >= amount, "Insufficient DF in pool");

        super._transfer(pair, interactiveContract, amount);
        IPancakePair(pair).sync();

        emit recycleDF_event(amount);
    }
    
    // 计算池子价值（以U为单位）
    function _calculatePoolValue(uint256 bnbPriceUsd) private  view returns (uint256) {
        (uint256 reserveDF, uint256 reserveBNB) = getReserves();
        if (reserveDF == 0 || reserveBNB == 0) return 0;
        
        uint256 bnbValue = (reserveBNB * bnbPriceUsd) / 10**18;
        return bnbValue;
    }
    
    function getBNBPrice() public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = USDT;
        
        try IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(10**18, path) returns (uint256[] memory amounts) {
            if (BNB_PRICE == 0) {
                return amounts[1];
            }
            if(amounts[1] > BNB_PRICE * 150 / 100 && amounts[1] < BNB_PRICE * 50 / 100){
                return BNB_PRICE;
            }else{
                return amounts[1];
            }
        } catch {
            return BNB_PRICE;
        }

        //uint256[] memory amounts = IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(10**18, path);
        //return amounts[1];
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









    //======================
    // 管理功能
    function setInteractiveContract(address _op) external{
        require(msg.sender == adminAddress || msg.sender == owner() || msg.sender == interactiveContract,"sender is wrong");
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
        isExcludedFromTax[oldAddress] = false;
        isExcludedFromTax[_op] = true;
        emit FoundationAddressUpdated(oldAddress, _op);
    }
    function setPancakePair(address _op) external onlyOwner {
        require(_op != address(0), "Cannot set to zero address");

        pancakePair = _op;
    }
    function setAdminAddress(address _op) external{
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
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
