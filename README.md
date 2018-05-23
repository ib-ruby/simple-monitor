# Simple Monitor
Simple Portfolio-Monitor for FA-Accounts on InteractiveBrokers

The monitor is realized with 470 lines of code using ib-ruby and the camping micro-web-framework. 
You can select any detected Account. In addition to basic information, such as the NetLiquidation, the used Margin and available Cash, all portfolio-positions are displayed. A simple form to place an emergency-order is provided, too.

Install Ruby 2.4+ (via rvm)
Initialize with 'bundle install' following with 'bundle update'

Start a TWS or a Gateway with multible Accounts (A Demo-Account is prefered)

Edit tws-alias.yml  and change the :host-Entry to the host running the TWS/Gateway (eg. 'localhost:7496').
If a connection is made with the Gateway, specify that port, too, eg 'localhost:4001'

Run the camping-Server 
```
camping simple_monitor.rb -p 3333
```

Open a Browser-Window at http://localhost:3333

enjoy



If an ascii-Browser like elinks is used, the following output is generated

```
TWS-Host: localhost: 7496  Status: Connected  Depot: [DUXXXXX] [Select Account] Refresh Disconnect  
DU167348  FirstUser                                                 Last Update: 17.04. 20:56:13
NetLiquidation:	877,430 EUR         RegTMargin:	133,902 EUR          TotalCashValue: 634,718 EUR
Cash    634,718 BASE  -78,028 AUD	4,884 EUR   -735,022 JPY	746,852 USD
Stocks	242,781 BASE   92,448 AUD     142,703 EUR     36,121 USD
Portfolio Positions   Size  Price (Entry)  Price (Market) Value (Market)  pnl  
Stock: BLUE EUR	      720   22.643         25.950         18,684          2,381
Stock: CBA AUD	      1004  79.363         92.080         92,448          12,767
Stock: CIEN USD	      812   23.675         21.425         17,397          -1,827
Stock: CSCO USD	      49    21.450         27.905         1,367           316
Stock: DBA USD	      1365  25.321         22.275         30,405          -4,158
Stock: GE USD         -500  24.961         27.015        -13,508          ( realized ) -204.93
Stock: LHA EUR	     10124  15.394         12.250         124,019         -31,827
Stock: NEU USD	     1      276.990        458.230        458             181

                               Pending-Orders
DU167348       Open  Stock CSCO USD sell 5  @ 4.500            Presubmitted         cancel
               Order:                       LMT GTC
                               Contract-Mask
Selected Account:    DU167348
Predefined Contracts:	 [list of Contratcs]
Symbol	             CSCO                   (if empty predefined Contract will be used)
Currency             USD                    con-id: 268084
Exchange             SMART                  CISCO SYSTEMS INC
Expiry	             201506                 Communications
Strike	             30.0                   Telecommunications
Right                p
Multiply             100                    
Type                 [option]                [verify]

            (x) Buy           ( ) Sell       [X] Whatif          [X] Transmit
Size        __________        (Limit) Price  ______________      (Aux) Price ____________________
OrderType   [Limit]           Validity       [GTC]               [submit] 

```
