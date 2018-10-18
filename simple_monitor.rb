require 'bundler/setup'
require 'ib-gateway'
require 'camping'
require 'yaml'
# reopen Gateway class and add Next-Account-Feature  (to_do: use enumerator to provide this feature)
module IB
	class Gateway
		def next_account account_or_id
			sa = account_or_id.is_a?(IB::Account) ? account_or_id :  @accounts.detect{|x| x.account == account_or_id }
			the_position = @accounts.index sa
			@accounts.size==1 ?  @accounts.first : @accounts.at( the_position+1 >=  @accounts.size ? 1: the_position +1 )  
		end

		def locate_contract con_id
			contract=nil
			active_accounts.detect{|a| contract = a.contracts.detect{|c| c.con_id == con_id.to_i  }}
			contract
		end


	end
end

Camping.goes :Ibo

module Ibo::Helpers
	def gw  # returns the gateway-object or creates it and does basic bookkeeping
		if IB::Gateway.current.nil?   # only the first time ...
			host, client_id = read_tws_alias{|s| [ s[:host].present? ? s[:host] :'localhost', s[:client_id].present? ? s[:client_id] :0 ] }
			# client_id 0 gets any open order
			gw = IB::Gateway.new(  host: host, client_id: client_id, 
				logger: Logger.new('simple-monitor.log') ,
				get_account_data: true ) do |g|
					g.logger.level=Logger::INFO
					g.logger.formatter = proc {|severity, datetime, progname, msg| "#{datetime.strftime("%d.%m.(%X)")}#{"%5s" % severity}->#{msg}\n" }
				end
				IB::Gateway.current.update_orders				 # read pending_orders
		end
		IB::Gateway.current # return_value
	end
	def account_name account, allow_blank: false  # returns an Alias (if not given the AccountID)
		the_name = read_tws_alias{ |s| s[:user][account.account]} ||  account.alias 
		allow_blank && ( the_name == account.account ) ? "" :	the_name.presence || account.alias # return_value
	end

	def get_account account_id  # returns an account-object
		account =gw.active_accounts.detect{|x| x.account == account_id } 
		yield( gw.next_account(account) ) if block_given?
		account # return_value
	end

  def	negative_position account, contract   # returns the negative position-size (if present) or ""
			pending_order =  account.orders.detect{|o| o.contract == contract}  #  overread pending orders
			the_p_position = account.portfolio_values.find{|p| p.contract == contract} unless !!pending_order
			the_p_position.present? ? -the_p_position.position.to_i  : ""
	end

	def read_tws_alias key=nil, default=nil  # access to yaml-config-file is not cached. Changes
																					 # take effect immediately after saving the yaml-dataset
																					 # a block has access to the raw-structure
		structure = File.exists?( 'tws_alias.yml') ?  YAML.load_file('tws_alias.yml') : nil
		if block_given? && !!structure
			yield structure
		else
		  structure[key]  || default
		end
	end

	def whatchlists # returns a hash: { :name => IB::Symbols Class }
		the_lists = read_tws_alias :watchlist,  [:Currencies]
		the_lists.map{ |x| [ x.to_s, IB::Symbols.allocate_collection( x )] rescue nil }.compact.to_h  
	end

	def all_contracts *sort
		sort = [ :sec_type ] if sort.empty?
		sort.map!{ |x| x.is_a?(Symbol) ? x : x.to_sym  }
		gw.all_contracts.sort_by{|x| sort.map{|s| x.send(s)} } 
	end

	def contract_size account,contract  # used to assign the alloclated amount to individual accounts
		v= account.portfolio_values.detect{|x| x.contract == contract }
		v.present? ? v.position.to_i : 0 
	end
end

module Ibo::Controllers
  class Index < R '/'
		def get
			@watchlists =  whatchlists
			if gw.active_accounts.size ==1 	# if a user-account is accessed
				@account =  gw.active_accounts.first     
				render :show_account
			else
				@accounts = gw.active_accounts
				render  :show_contracts
			end

		rescue IB::TransmissionError  => e
			@the_error = e
			render :show_error 
		end
	end

  class StatusX
    def get action
      view_to_render = :show_contracts # :show_account 
			@watchlists =  whatchlists
      case action.split('/').first.to_sym
			when :disconnect
				gw.disconnect
				IB::Gateway.current=nil
      view_to_render = :show_account 
			when :lists

			when :reload , :connect
				gw.for_active_accounts{|a| a.update_attribute :last_updated, nil } # force account-data query
				gw.get_account_data
				gw.update_orders
				@accounts = gw.active_accounts
			when :contracts 
				gw.update_orders
				@accounts = gw.active_accounts
			end  # case
			render view_to_render
		end		# def
	end			# class

  class SelectAccountX # < R '/Status'
	def init_account_values	
		account_value = ->(item) do 
			gw.get_account_data( @account )
			@account.simple_account_data_scan(item)
			.map{|y| [y.value,y.currency] unless y.value.to_i.zero? }
			.compact 
			.sort{ |a,b| b.last == 'BASE' ? 1 :  a.last  <=> b.last } # put base element in front
		end
		{ 'Cash' =>  account_value['TotalCashBalance'],
		'FuturesPNL' =>  account_value['PNL'],
		'FutureOptions' =>  account_value['FutureOption'],
		'Options' =>  account_value['OptionMarket'],
		'Stocks' =>  account_value['StockMarket'] }  # return_value
	end
	def get account
		@account= get_account(account){ |y|   @next_account = y }
		@contract = IB::Stock.new
		@account_values = init_account_values
		@watchlists =  whatchlists
		render :contract_mask
	end
 end

 class CloseContractXN
	 def get account_id,  con_id
		@watchlists =  whatchlists
		@account = get_account( account_id ){| y| @next_account = y} 
		@contract = @account.contracts.detect{|x| x.con_id == con_id.to_i }.verify!
		render  :contract_mask
	 end
 end

 class CloseAllN
	 def get con_id
		 puts "con_id #{con_id}"
		 @contract = gw.locate_contract con_id.to_i 
		 @contract.market_price # put the price into the misc-attribute 
		 @sizes =  gw.active_accounts.map{ |a| contract_size( a , @contract ) }   # contract_size is a helper method
		 @accounts = gw.active_accounts
		render  :close_contracts
			
	 end
 end

 class ContractX # < R '/contract/(\d+)/select'
	 def post account_id
		 # if symbol is specified, search for the contract, otherwise use predefined contract
		 # The contract itself is initialized after verifying 
		 @account = get_account( account_id ){| y| @next_account = y} 
		 @watchlists =  whatchlists

		 c = if  @watchlists.keys.include? input.keys.first
					 puts "watchlists #{@watchlists}"
					 puts "input #{input.inspect}"
					 begin
						 @the_selected_watchlist = Integer input.values.first
						 @watchlists[input.keys.first][@the_selected_watchlist]
					 rescue ArgumentError
						 @watchlists[input.keys.first].send @the_selected_watchlist = input.values.first.to_sym 
					 end
				 else
					 @input[:right] = @input['right'][0].upcase if input['sec_type']=='option'
					 @input[:sec_type] = @input['sec_type'].to_sym
					 IB::Contract.build @input #.reject{|x| ['right','sec_type'].include?(x) }
				 end
		 c.exchange = nil unless c.con_id.zero?  # walkaround to enable verifying by con_id
		 count=  c.verify{|y| @contract =  y}
		 @message = if count.zero?  
									@contract ||= IB::Stock.new
									"Not a valid contract, details in Log" 
								else
									""
								end
		 # include contract in contracts-collection of the account
		 @account.contracts.update_or_create( @contract  ) unless @contract.con_id.to_i.zero? || @the_selected_watchlist.present?
		 render  :contract_mask
	 end
 end

	class MultiOrderN
		def post con_id
			contract = gw.locate_contract( con_id ).verify!
			accounts = @input['total_quantity']
			order_fields =  @input.reject{|x| x=='total_quantity'}   # all other input-fields
			puts order_fields.inspect
			accounts.each{|x,y| get_account(x).place_order( order: IB::Order.new(order_fields.merge total_quantity: y), contract: contract, convert_size: true ); sleep 0.1}
	puts "---"
			
			redirect Index
		end
	end
 class OrderXN 
	def get account_id, local_id  # use get request to cancel an order
		account = get_account account_id 
		puts "selected local_id: #{local_id}"
		order = account.locate_order local_id: local_id.to_i 
		if order.is_a? IB::Order
			gw.cancel_order order 
			sleep 1 
		else
			gw.logger.error{ "Unable to cancel specified Order( local_id: #{local_id} )" }
		end
		redirect  R(SelectAccountX, account.account)
	end


	def post account_id, con_id  # use put request to place an order
		account =  get_account account_id 
		contract= account.contracts.detect{|x| x.con_id == con_id.to_i }
		account.place_order	order: IB::Order.new(@input), contract:contract, convert_size: true
		sleep 1 
		redirect R(SelectAccountX, account.account)
	end
 end

 class Style < R '/styles\.css'
   STYLE = File.read(__FILE__).gsub(/.*__END__/m, '')
   def get
     @headers['Content-Type'] = 'text/css; charset=utf-8'
#		 @headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
     STYLE
   end
 end

end # module controller

module Ibo::Views
	def layout
		html do
			head do
				title { "IB Simple-Monitor & Emergency Trading-Desk" }
				link :rel => 'stylesheet', :type => 'text/css', :href => '/styles.css', :media => 'screen'
			end
			show_index
			body { self << yield }
		end
	end

	def show_contracts
		pending_orders = -> {  @accounts.map( &:orders ).flatten.compact  if  @accounts.present? }  # any account

		table do
			tr.exited do
				td { "Contracts" }
				@accounts.each{|account| td.number { a account_name(account), href: R(SelectAccountX, account.account) } }
			end
			all_contracts( :sec_type, :symbol, :expiry,:strike ).each do | contract |
				tr do
					td{ a  contract.to_human[1..-2], href: R(CloseAllN, contract.con_id) }
					@accounts.each{|a| td.number contract_size(a,contract) } 
				end 
			end
			_pending_orders( @accounts.size+1 ){ pending_orders[] }
		end
	end   # def

	def show_account
		pending_orders = -> {  @account.orders  if  @account.present? }  # only for the specified account
		table do
			if @account.present? && @account.account_values.present? 
				tr( class:  "lines") do
					td( colspan: 1) { @account.account }
					td( colspan: 2) { account_name  @account, allow_blank: true }
					td.number( colspan: 3){ "Last Update: #{@account.last_updated.strftime("%d.%m. %X")}" } 
					td.number { a "Next: #{account_name(@next_account)}", href: R(SelectAccountX, @next_account.account)	}
				end
				_account_infos(@account)
				if @account_values.present?
						@account_values.each{|y| _details(y) unless y.last.empty? }  #y ::["FuturesPNL", [["-255", "BASE"], ["-255", "EUR"]]]
				end
			end
			if @account.present? && @account.portfolio_values.present?
				tr.exited do
					td( colspan:2){ "Portfolio Positions" }
					td.number "Size"
					td.number "Price (Entry)"
					td.number "Price (Market)"
					td.number "Value (Market)"
					td.number "pnl"
					td { '&#160;' }
				end
				@account.portfolio_values.each{|x| _portfolio_position(x) }
			end
			_pending_orders(8){ pending_orders[] }
		end
	end

	def close_contracts
		show_contracts
		form action: R(MultiOrderN,  @contract.con_id), method: 'post' do
			table do
				#		tr.exited  { td( colspan:3, align:'right' ) { 'Multi Account Order Mask' } }
				tr.exited do
					td( colspan:2 ){@contract.to_human[1..-2] }
					td( colspan:3 , align: :right){ "Emergency Close" }
				end
				tr{  td "Account"  ;  @accounts.each{ |a| td(align: :center){ account_name(a) } } }
				tr do
					td 'Size'
					@accounts.each do |a|
						td { input type: :text, value: negative_position( a, @contract) , name: "total_quantity[#{a.account}]" }  #a.account };
					end
				end
				tr{ td {" --- "} }
				_order_attributes_and_submit
			end
		end
	end

	def contract_mask
		input_row = ->( field , comment='' ) do
			tr { td( field.capitalize ); td { input type: :text, value: @contract[field] , name: field }; td comment }
		end
		show_account
		table do
			tr.exited do
				td( colspan:3, align:'center' ) { 'Contract-Mask' }
			end
			tr{ td @message if @message.present? }
			tr { td( colspan: @watchlists.size ){ "Whatchlists"  }}
			tr do
				@watchlists.each do | watchlist_name, watchlist_class |
					td do 
						form action: R(ContractX, @account.account), method: 'post' do
							puts "TSW +#{@the_selected_watchlist}"
							table do
								tr { td watchlist_name }
								tr do
									td do
										select( name: watchlist_name, size:1 ) do
											watchlist_class.all.each do |y| 
												if @the_selected_watchlist.present? && @the_selected_watchlist == y
													option( selected: 'selected',value: y ){ watchlist_class[y].to_human[ 1..-2 ] } 
												else
													option( value: y ){ watchlist_class[y].to_human[ 1..-2 ] } 
												end
											end # each
										end   # select
									end     # td
								end       # tr
								tr{	td { input type: 'submit', class: 'submit',  value:  "Use #{watchlist_name}"  }}
							end # table
						end # form
					end	  # td
				end # each
			end   # tr
		end  # table

		form action: R(ContractX, @account.account), method: 'post' do

			table do
				input_row['exchange', @contract.contract_detail.present? ? @contract.contract_detail.long_name : '']
				input_row['symbol', @contract.contract_detail.present? ? " market price : #{@contract.market_price}  (delayed)" : '' ]
				input_row['currency', @contract.contract_detail.present? ? " con-id : #{@contract.con_id}" : '' ]
				input_row['expiry', @contract.contract_detail.present? ? " expiry: #{@contract.last_trading_day}" : '']
				input_row['right',  @contract.is_a?(IB::Option) ? @contract.right : '']
				input_row['strike', @contract.strike.to_i > 0 ? @contract.strike : '']
				input_row['multiplier', @contract.multiplier.to_i >0  ? @contract.multiplier : '']

				tr do
					td "Type"
					td do
						select( name: 'sec_type', size:1 ) do
							IB::Contract::Subclasses.each do |x,y| 
								if @contract.sec_type == x.to_sym
									option( selected: 'selected' ){ x }
								else
									option x
								end
							end
						end
					end
					td { input :type => 'submit', :class => 'submit', :value => 'Verify'  }

				end  # tr
			end	  # table
		end #form
		_order_mask if @contract.contract_detail.present? || @contract.is_a?( IB::Bag )
	end # contract_mask


  def _order_mask
		form action: R(OrderXN, @account.account, @contract.con_id), method: 'post' do
			table do
				tr.exited do
					td
					td @contract.symbol  # {"#{@contract.to_human }" }
					td( colspan: 4, align: 'left' ) { 'Order-Mask' }
				end
				tr do
					td 'Size'
					td { input type: :text, value: negative_position( @account, @contract) , name: 'total_quantity' };
				end
				_order_attributes_and_submit
			end
		end
	end 

	def _order_attributes_and_submit

		the_price = -> { @contract.misc }  # holds the market price from the previous query
		tr do
			td '(Primary) Price :'
			td { input type: :text, value: the_price[] , name: 'limit_price' };
			td( align: :right ){ '(Aux) Price  :' }
			td { input type: :text, value: '' , name: 'aux_price' };
		end
		tr do
			td 'Order Type :'
			td { select( name: "order_type", size:1){ IB::ORDER_TYPES.each{ |a,b| option( value: a){ b } } } }
			td( align: :right ){ 'Validity :' }
			td { select( name: 'tif', size:1){[ "GTC", "DAY" ].each{|x| option x }} }
		end
		tr{ td(colspan:2){""};	td { input :type => 'submit', :class => 'submit', :value => 'submit' } }
	end
	def show_index
			table  do
				tr do
					if !!( IB::Gateway.current )
						td "TWS:: #{gw.get_host}"
						td { a 'OverView',  href: R(StatusX, :contracts) }
				#		td { a 'Watchlists', href: R(StatusX, :lists) }   # todo 
						td { a 'Refresh',    href: R(StatusX, :reload) }
						td { a 'Disconnect', href: R(StatusX, :disconnect) }
					else
					  td( colspan: 2) { "TWS:: NC" }
						td { a 'Connect',    href: R(StatusX, :connect) } 
					end # branch

				end # tr
			end # table
	end # def

	def show_error
 # todo
	end

	def close_all contract

	end
## partials
	def _details( d )
		tr do
			td d.first
			d.last.each do |x,y|
				td.number "#{ActiveSupport::NumberHelper.number_to_delimited(x)} #{y}"
			end
		end
	end

	def _contract(c)
		tr do
			td c.sec_type.to_s.upcase
			td c.symbol
			td c.currency
			td c.exchange
			td.number c.con_id
		end
	end

	def _pending_orders( columns ) 
		pending_orders = *yield 
			if pending_orders.empty?
				tr.exited { td( colspan: columns, align: 'center'){ 'No Pending-Orders' } }
			else
				tr.exited { td( colspan: columns, align:'center' ) { 'Pending-Orders' } }
				pending_orders.each {  |a| tr { _order(a)} }  
			end
	end

	def _order( o )
		my_price = -> do
			if o.limit_price.present? && o.limit_price != 0
				if o.aux_price.present? && o.aux_price != 0
					"@ #{ActiveSupport::NumberHelper.number_to_rounded(o.limit_price)} / #{ActiveSupport::NumberHelper.number_to_rounded(o.aux_price)} "
				else
					"@ " + ActiveSupport::NumberHelper.number_to_rounded(o.limit_price) 
				end
			elsif o.aux_price.present? && o.aux_price != 0 
				"@ " + ActiveSupport::NumberHelper.number_to_rounded(o.aux_price) 
			else 
				" "
			end
		end
		character = -> do
			if o.order_states.any?{|x| x=='Executed'}
				"Finished "
			elsif o.order_states.any?{|x| x=='Canceled'}
				"Canceled "
			else
				"Open "
			end + "Order:"
		end
		tr do
			td o.account
			td character[]
			td o.contract.to_human[1..-2] || "no Contract Info saved"
			td "#{o.side} #{o.quantity}  #{ o.order_type } #{o.tif}"
			td my_price[]
			td o.order_states.map{|x| x.status }.join(';')
			td { a 'cancel' , href: R(OrderXN, o.account, o.local_id ) } if o.local_id >0 
		end
	end

	def _account_infos( a )
		tr do
			_account_value a.simple_account_data_scan('NetLiquidation').first
			_account_value a.simple_account_data_scan('InitMarginReq').first  
			_account_value a.simple_account_data_scan('TotalCashValue').first
		end
	end 

	def _account_value( av )
		td(colspan:2) do
			unless av.nil? || av.key.nil?	
		       	av.key.to_s + ': ' + ActiveSupport::NumberHelper.number_to_currency( av.value, precision:0, unit: av.currency, format: '%n %u' ).to_s 
			end
		end
	end 

	def _portfolio_position(pp)
		the_multiplier = ->{ pp.contract.multiplier.zero? ? 1: pp.contract.multiplier }
		tr do
			td(colspan:2){ a  pp.contract.to_human[1..-2], href: R(CloseContractXN  , @account.account, pp.contract.con_id ) }
			td.number pp.position.to_i 
			td.number  ActiveSupport::NumberHelper.number_to_rounded( pp.average_cost / the_multiplier[] )
			td.number  ActiveSupport::NumberHelper.number_to_rounded( pp.market_price )
			td.number "%15.2f " % pp.market_value				
	#		ActiveSupport::NumberHelper.number_to_delimited(
#				ActiveSupport::NumberHelper.number_to_rounded(  pp.market_value, precision:0 a
			if pp.realized_pnl.to_i.zero?
				td.number  ActiveSupport::NumberHelper.number_to_delimited(
					ActiveSupport::NumberHelper.number_to_rounded(  pp.unrealized_pnl, precision:0 ))
			elsif pp.realized_pnl.present?
				td.number "( realized ) #{ ActiveSupport::NumberHelper.number_to_delimited( pp.realized_pnl )}"
			end
		end

	end
end # module 

__END__
* {
  margin: 0;
  padding: 0;
}
body {
  font: normal 14px Arial, 'Bitstream Vera Sans', Helvetica, sans-serif;
  line-height: 1.5;
}
  h1, h2, h3, h4 {
    font-family: Georgia, serif;
    font-weight: normal;
  }
  h1 {
    background-color: #EEE;
    border-bottom: 5px solid #6F812D;
    outline: 5px solid #9CB441;
    font-weight: normal;
    font-size: 3em;
    padding: 0.5em 0;
    text-align: center;
  }
  h2 {
    margin-top: 1em;
    font-size: 2em;
  }
  h1 a { color: #143D55; text-decoration: none }
  h1 a:hover { color: #143D55; text-decoration: underline }
  h2 a { color: #287AA9; text-decoration: none }
  h2 a:hover { color: #287AA9; text-decoration: underline }
  #wrapper {
  margin: 3em auto;
width: 700px;
  }
  p {
    margin-bottom: 1em;
  }
  p.info, p#footer {
    color: #999;
    margin-left: 1em;
  }
  p.info a, p#footer a {
    color: #999;
  }
  p.info a:hover, p#footer a:hover {
    text-decoration: none;
  }
  a {
    color: #6F812D;
  }
  a:hover {
    color: #9CB441;
  }
  hr {
    border-width: 5px 0;
    border-style: solid;
    border-color: #9CB441;
      border-bottom-color: #6F812D;
      height: 0;
  }
  p#footer {
    font-size: 0.9em;
    margin: 0;
    padding: 1em;
    text-align: center;
  }
  label {
    display: block;
    width: 150px;
    float: left;
    margin: 2px 4px 6px 4px;
    text-align: right;
    }
  }
  input, textarea {
    padding: 5px;
    margin-bottom: 1em;
    margin-right: 490px;
    width: 200px;
  }
  input.submit,  select {
    width: auto;
          border: 1px solid #006;
	      background: #9cf;
  }
  textarea {
    font: normal 14px Arial, 'Bitstream Vera Sans', Helvetica, sans-serif;
    height: 300px;
    width: 400px;
  }
  table {border: solid gray; 
	 width: 99%;
	 border-collapse: collapse;
  }
  tr.alternate { background: #A9D4BF; }
  tr.lines { 	 border-top: 2px solid  #6F812D; font-weight: bold;}
  tr.exited { background: #999 }
  tr.underline { border-top: 2px solid  #6F812D;}
  
  td.number {
    text-align: right;
  }
