# Simple Monitor
Portfolio-Monitor for FA-Accounts on InteractiveBrokers

**Base Szenario:** Some trading approach is performed on a remote system. There is at least a reverse-ssh tunnel enabling basic administrative operations. One can establish a remote `tmux`-session, one window is starting the `simple_monitor`, one runs an `elinks`-session displaying the output. 

The monitor is realized with 430 lines of code using __`IB-Ruby`__ and the camping micro-web-framework. It generates pure HTML and uses some CSS, too, providing an overview on every browser, including text-based ones, like `elinks`.

You can select all Accounts. Basic information, such as the NetLiquidation, the used Margin and available Cash  are shown.  All Portfolio-Positions  (Contracts) are displayed. A simple form to place an emergency-order (i.e. a "Close-Position"-Feature) is provided, too. New Positions can be established through their basic properties (see below).

#### Getting Started
Install Ruby 2.5+ (via rvm)
Initialize with `bundle install` following with `bundle update`

Start a TWS or a Gateway with multible Accounts.

Edit tws-alias.yml  and change the `:host`-Entry to the host running the TWS/Gateway (eg. `localhost:7496`).
If a connection is made with the Gateway, specify that port, too, eg `localhost:4001`. If no Account-Alias is set in 
Account-Management,  local Aliases can be defined in the yaml-dataset.

Run the camping-Server 
```
camping simple_monitor.rb -p 3333
```

Open a Browser-Window at http://localhost:3333

enjoy


#### The Output
If an ascii-Browser like `elinks` is used, the following output is generated

```
  TWS-Host: localhost: 4002 Status: Connected Depot: [_FirstUser_] [ Select Account ] Contracts Refresh Disconnect

   DU167348     FirstUser                                               Last Update: 14.09. 11:28:44
   NetLiquidation: 909,261  FullInitMarginReq: 25,274 EUR               TotalCashValue: 843,818
   EUR                                                                  EUR
   Portfolio Positions      Size            Price (Entry)               Price        Value         pnl            
                                                                        (Market)     (Market)
   Stock: BLUE EUR SBF      720             22.643                      16.401       11,809        -4,495
   Stock: BXB AUD ASX       0               0.000                       11.105       0             ( realized )
                                                                                                   -179.81
   Stock: CIEN USD NYSE     812             23.675                      31.500       25,578        6,354
   Stock: CSCO USD NASDAQ   44              21.450                      47.420       2,086         1,143
   Stock: DBA USD ARCA      1366            25.317                      17.086       23,339        -11,244
   Stock: DBB USD ARCA      -1              17.630                      15.832       -16           2
   Stock: J36 USD SGX       100             64.552                      60.723       6,072         -383
   Stock: NEU USD NYSE      1               276.990                     397.970      398           121
   Stock: WFC USD NYSE      100             52.960                      55.050       5,505         209
                                                   Pending-Orders
   DU167348     Open Order: Future: NQ      sell limit                  @ 7625.000   Submitted     cancel
                            20180921 USD    good_till_cancelled

                        Contract-Mask
   Selected Account:     DU167348
   Predefined Contracts: [_______________________] [ Use ]

   Exchange   _GLOBEX______________ E-mini NASDAQ 100 Futures
   Symbol     _NQ__________________ market price : (delayed)
   Currency   _USD_________________ con-id : 279396750
   Expiry     _____________________
   Right      _____________________
   Strike     _____________________
   Multiplier _20__________________ 20
   Type       [_future_]           [ Verify ]

              NQ                           Order-Mask
   Size       _2___________________        (Primary) Price __2600_______________ (Aux) Price _____________________
   Order Type [_limit ____________________] Validity        [_GTC_]                 [ submit ]


```
In Addition, there is an overview of all allocated Contract-Positions
```
 TWS-Host: localhost: 4002 Status: Connected Depot: [_________] [ Select Account ] Contracts Refresh Disconnect

   Contracts            FirstUser   DU167349
   Future: NQ 20180921  0           0
   USD
   Stock: ALB USD NYSE  0           48
   Stock: BLUE EUR SBF  720         740
   Stock: BXB AUD ASX   0           0
   Stock: CBA AUD ASX   0           1032
   Stock: CIEN USD NYSE 812         28
   Stock: CSCO USD      44          51
   NASDAQ
   Stock: D USD NYSE    0           1264
   Stock: DBA USD ARCA  1366        273
   Stock: DBB USD ARCA  -1          0
   Stock: GE USD NYSE   0           -240
   Stock: J36 USD SGX   100         0
   Stock: LHA EUR IBIS  0           5146
   Stock: NEU USD NYSE  1           0
   Stock: NTR USD NYSE  0           223
   Stock: T USD NYSE    0           -100
   Stock: WFC USD NYSE  100         0
                      Pending-Orders
   DU167348             Open Order: Future: NQ 20180921 sell limit good_till_cancelled @ 7625.000 Submitted cancel
                                    USD

```



