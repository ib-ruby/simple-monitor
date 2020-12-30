require 'bundler/setup'
require 'ib-gateway'
require 'ib/symbols'
require 'ib/market-price'
require 'camping'
require 'yaml'
# reopen Gateway class and add Next-Account-Feature  (to_do: use enumerator to provide this feature)
module IB
	class Gateway
		def next_account account_or_id
			a =  clients 
			sa = account_or_id.is_a?(IB::Account) ? account_or_id : a.detect{|x| x.account == account_or_id }
			the_position = a.index sa
			a.size==1 ||  the_position == a.size-1  ? a.first : a.at( the_position+1 )  
		end
	end
end

Camping.goes :Ibo

module Ibo::Helpers
	def gw  # returns the gateway-object or creates it and does basic bookkeeping
		if IB::Gateway.current.nil?   # only the first time ...
			set_alias = ->(account) do  # lambda to transfer alias name from yaml-file to account.alias
				yaml_alias = read_tws_alias{ |s| s[:user][account.account]} 
				account.alias = yaml_alias if yaml_alias.present? && !yaml_alias.empty?
			end

			host, client_id = read_tws_alias{|s| [ s[:host].present? ? s[:host] :'localhost', s[:client_id].present? ? s[:client_id] :0 ] } # client_id 0 gets any open order
			gw=IB::Gateway.new(  host: host, client_id: client_id,	serial_array: true,
											logger: Logger.new('simple-monitor.log') ,
											watchlists: read_tws_alias(:watchlist),
											get_account_data: true ) do |g|
												g.logger.level=Logger::INFO
												g.logger.formatter = proc {|severity, datetime, progname, msg| "#{datetime.strftime("%d.%m.(%X)")}#{"%5s" % severity}->#{msg}\n" }
											end
			gw.update_orders				 # read pending_orders
			excluded_accounts = read_tws_alias(:exclude)
#i			excluded_accounts.keys.each{| a | iib.for_selected_account(a.to_s){|x| x.disconnect! }} if excluded_accounts.present?			# don't handle excluded Accounts
			gw.clients.each{ |a| set_alias[a]} 
			set_alias[gw.advisor]
      update_account_data
		end
		IB::Gateway.current # return_value
	end

	def account_name account, allow_blank: false  # returns an Alias (if not given the AccountID)
		allow_blank && ( account.account == account.account ) ? "" : account.alias # return_value
	end

	def update_account_data
    # will be called from »gw-helper«, thus gw may not be initialized
	IB::Gateway.logger.info{ "updating account data" }	
		IB::Gateway.current.get_account_data watchlists: watchlists
		IB::Gateway.current.clients.each do |c|
			c.portfolio_values.each do  |p|
				the_contract = IB::Gateway.current.all_contracts.detect{|x| x.con_id.to_i == p.contract.con_id.to_i }
				the_contract.misc =  p.market_price.to_f.round 3
			end
		end
		IB::Gateway.current.update_orders
	end

	def locate_contract con_id, account = nil
		watchlist_entry = -> {watchlists.map{|y| y.detect{|c| c.con_id.to_i == con_id.to_i} rescue nil }.compact.first }
		c= if account.present?
				 account.locate_contract( con_id.to_i ) || account.complex_position( con_id.to_i )
			 else
				 gw.all_contracts.detect{|x| x.con_id.to_i == con_id.to_i }
			 end
		(c.nil? ? watchlist_entry[] : c)
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

	def watchlists # returns an array of preallocated watchlists [IB::Symbols.Class, ... ]
		the_lists = read_tws_alias :watchlist,  [:Currencies]
		the_lists.map{ |x|  IB::Symbols.allocate_collection( x ) rescue nil }.compact
	end

	def all_contracts *sort
		sort = [ :sec_type ] if sort.empty?
		sort.map!{ |x| x.is_a?(Symbol) ? x : x.to_sym  }
		gw.all_contracts.sort_by{|x| sort.map{|s| x.send(s)} }
	end

	def contract_size account,contract  # used to assign the allocated amount to individual accounts
		v= account.portfolio_values.detect{|x| x.contract == contract }
		v.present? ? v.position.to_i : 0
	end

	def valid_price? element   # element is  a hash with keys: limit_price and aux-prcie
     (element['limit_price'].to_i.abs  | element['aux_price'].to_i.abs) > 0
	end

	def initialize_watchlist_and_account account_id
		@watchlists =  watchlists.map{|w| w.all.send(:size) >0 ?  w : nil }.compact  # omit empty watchlists
		@account=  gw.clients.detect{|a| a.account == account_id}
		@next_account = gw.next_account(@account)
	end

	def read_order_status  # returns the count of detected orderstatus-messages 
    (gw.tws.received[:OrderStatus] || []).size
	end
end

module Ibo::Controllers
  class Index < R '/'
		def get
			@watchlists =  watchlists
			if gw.clients.size ==1	# if a single - user-account is accessed
				@account =  gw.clients.first
				render :show_account
			else
				@accounts = gw.clients
				render  :show_contracts
			end
		rescue IB::TransmissionError  => e
			@the_error_message = e
			render :show_error
		end
	end

  class StatusX
    def get action

			if gw.check_connection
				view_to_render = :show_contracts # :show_account 
				@watchlists =  watchlists
				@accounts = gw.clients
				case action.split('/').first.to_sym
				when :disconnect
					gw.disconnect
					IB::Gateway.current=nil
					view_to_render = :show_account 
				when :lists

				when :reload , :connect	
					gw.tws.clear_received 
					gw.clients.each{|a| a.update_attribute :last_updated, nil } # force account-data query
					update_account_data
				when :contracts 
					gw.update_orders
				end  # case
				render view_to_render
			else
				@error_message =  "No Connection"
				render :show_error
			end
		end		# def
	end			# class

  class SelectAccountX # < R '/Status'
	def init_account_values	
		account_value = ->(item) do 
			gw.get_account_data( @account, watchlists: watchlists )
			@account.account_data_scan(item)
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
	def get account_id
		if gw.check_connection
			initialize_watchlist_and_account account_id
			@contract = nil #IB::Stock.new con_id: -2
			@account_values = init_account_values
			render :contract_mask
		else
			@error_message =  "No Connection"
			render :show_error
		end
	end
 end

 class CloseContractXX
	 def get account_id,  con_id
		 initialize_watchlist_and_account account_id
		 @contract = @account.locate_contract( con_id) || @account.complex_position( con_id )
		 gw.logger.info{ "CloseContract  #{@contract.misc}"  }
		render  :contract_mask
	 end
 end

 class CloseAllN
	 def get con_id
		 if gw.check_connection
			 @contract = locate_contract(con_id) # gw.all_contracts.detect{|x| x.con_id.to_i == con_id.to_i }
			 render :show_error unless @contract.is_a?  IB::Contract
		#	 @contract.misc= @contract.market_price  unless @contract.misc.present? # put the price into the misc-attribute 
			 @sizes =  gw.clients.map{ |a| contract_size( a , @contract ) }   # contract_size is a helper method
			 @accounts = gw.clients
			 render  :close_contracts
		 else
			 @error_message =  'No Connection'
			 render :show_error
		 end
	 end
 end

 class ContractX # < R '/contract/(\d+)/select'
	 def post account_id
		 if gw.check_connection
			 the_watchlist = -> {IB::Symbols.allocate_collection input.keys.first.to_sym }
			 initialize_watchlist_and_account account_id
			 # input (a) --> Hash: Watchlist_name => symbol as string
			 #       (b) --> Hash of qualified contract attributes from formular
			 contract = if  @watchlists.map(&:to_human).include? input.keys.first
										 begin
											 @the_selected_watchlist = Integer input.values.first  #raises ArgumentError if alpanumeric
											 the_contract=the_watchlist[][@the_selected_watchlist]
										 rescue ArgumentError
											 the_contract= the_watchlist[].send( @the_selected_watchlist = input.values.first.to_sym )
										 end
									 else
										 @input[:right] = @input['right'][0].upcase if input['sec_type']=='option'
										 @input[:sec_type] = @input['sec_type'].to_sym
										 IB::Contract.build @input
									 end
			 @contract = contract.verify &.first
			 @contract.misc = @contract.market_price if @contract.is_a?(IB::Contract)
			 gw.clients.detect{|a| a.account == account_id} &.contracts.update_or_create( @contract, :con_id)  unless  @contract.con_id <0
			 render  :contract_mask
		 else
			 @error_message =  'No Connection'
			 render :show_error
		 end
	 end
 end

	class MultiOrderN
		def post con_id
			if gw.check_connection
				contract =  locate_contract(con_id)
				order_fields =  @input.reject{|x| x=='total_quantity'}   # all other input-fields
				count_of_order_state = read_order_status
				gw.tws.update_next_order_id
				number_of_transmitted_orders = 0
				@input['total_quantity'].each do |x,y|
					account =  gw.clients.detect{|a| a.account == x}
					unless  y.nil? || y.to_s.empty? || y.to_i.zero? || !valid_price?(order_fields) ||  !account.is_a?(IB::Account)
						account.place_order( order: IB::Order.new(order_fields.merge total_quantity: y), contract: contract, convert_size: true ); sleep 0.1
						number_of_transmitted_orders +=1
					end
				end
				i=0; loop do
					break if read_order_status >= number_of_transmitted_orders + count_of_order_state || i> 30
					sleep 0.2; i=i+1
				end
				gw.update_orders
				gw.tws.clear_received    # reset received-array
				redirect Index
			else
				@error_message =  'No Connection'
				render :show_error
			end
		end
	end

	class OrderXX
		def post account_id, con_id  # (POST Request) used to  to place an order
			if gw.check_connection
				account = gw.clients.detect{|a| a.account == account_id }
				contract= locate_contract( con_id )
				if !contract.is_a?(IB::Contract)
					render "Placing failed. Contract not evaluated: con_id:  #{con_id}"
				elsif  !valid_price?(@input)  
					gw.logger.error{ "Order-size not recognized for #{contract.to_human}" }
				else
					count_of_order_state_messages = read_order_status
					gw.tws.update_next_order_id
					gw.logger.info { "Placing Order on #{contract.to_human}" }
					account.place_order	order: IB::Order.new(@input), contract: contract, convert_size: true
					i=0; loop{ break if read_order_status >  count_of_order_state_messages || i> 30; sleep 0.2; i=i+1 }
					gw.update_orders
					gw.tws.clear_received
					redirect R(SelectAccountX, account_id)
				end
			else
				@error_message =  'No Connection'
				render :show_error
			end
		end
		def get account_id, local_id  # (Get-Request) used  to cancel an order
			if gw.check_connection
				account = gw.clients.detect{|a| a.account == account_id }
				order = account.locate_order local_id: local_id.to_i 
				if order.is_a? IB::Order
					gw.cancel_order order 
					sleep 1 
				else
					gw.logger.error{ "Unable to cancel specified Order( local_id: #{local_id} )" }
				end

				gw.update_orders # outside of mutex-env.
				redirect  R(SelectAccountX, account_id)
			else
				@error_message =  'No Connection'
				render :show_error
			end
		end

	end

 class Style < R '/styles\.css'
   STYLE = File.read(__FILE__).gsub(/.*__END__/m, '')
   def get
     @headers['Content-Type'] = 'text/css; charset=utf-8'
		 @headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
		 @headers["Pragma"] = "no-cache"
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
			all_contracts( :sec_type, :symbol, :expiry,:strike ).each do | c |
				if c.con_id.present? && c.con_id > 0 
					tr do
						td{  a c.to_human[1..-2], href: R(CloseAllN, c.con_id)  }
						@accounts.each{|a| td.number contract_size(a,c) } 
					end 
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
					td.number { a "Next: #{account_name(@next_account)}", href: R(SelectAccountX, @next_account.account)	if @next_account.present?}
				end
				_account_infos(@account)
				if @account_values.present?
						@account_values.each{|y| _details(y) unless y.last.empty? }  #y ::["FuturesPNL", [["-255", "BASE"], ["-255", "EUR"]]]
				end
			end
			if @account.present? && @account.focuses.present?
				tr.exited do
					td( colspan:2){ "Portfolio Positions" }
					["Size","Price (Entry)","Price (Market)","Value (Market)","pnl"].each{|n| td.number n}
					td { '&#160;' }
				end

				@account.focuses.each do | watchlist, positions |
					tr.exited do
						td( colspan:1){ "Category  -->" }
						td.number( colspan:7){ watchlist.to_human }
					end
					tr do
						positions.each do | contract, list_of_portfolio_values |
							if list_of_portfolio_values.size == 1
								_portfolio_position( list_of_portfolio_values.first )
							else
								_portfolio_position( contract.fake_portfolio_position( list_of_portfolio_values ) )
								list_of_portfolio_values.each{|x| _portfolio_position(x, prefix: "-> ") }
							end  #if
						end		 # each	
					end			 # tr	
				end				 # each
			end					# if
			_pending_orders(8){ pending_orders[] }
		end						# table
	end							# def

	def close_contracts
		show_contracts
		form action: R(MultiOrderN,  @contract.con_id), method: 'post' do
			table do
				tr.exited do
					td( colspan:2 ){@contract.to_human[1..-2] }
					td( colspan:3 , align: :right){ "Emergency Close" }
				end
				tr{  td "Account"  ;  @accounts.each{ |a| td(align: :center){ account_name(a) } } }
				tr do
					td 'Size'
					@accounts.each do |a|
						td { input type: :text, value: -contract_size( a, @contract) , name: "total_quantity[#{a.account}]" }  #a.account };
					end
				end
				tr{ td " --- " }
				_order_attributes_and_submit
			end
		end
	end

	def contract_mask
		input_row = ->( field , comment='' ) do
			the_value =  @contract.present? ? @contract[field] : "" 
			tr { td( field.capitalize ); td { input type: :text, value: the_value , name: field }; td comment }
		end
		show_account
		table do
			tr{ td @message if @message.present? }
			tr { td( colspan: 3 ){ "Watchlists"  }}
			tr do
				@watchlists[0..2].each.with_index do |  watchlist_class , i|
					td do 
						form action: R(ContractX, @account.account), method: 'post' do
							table do
								tr { td watchlist_class.to_human }
								tr do
									td do
										select( name: watchlist_class.to_human, size:1 ) do
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
								tr{	td { input type: 'submit', class: 'submit',  value:  "Use #{watchlist_class.to_human}"  }}
							end # table
						end # form
					end	  # td
				end # each
			end   # tr
		end  # table
		if @contract &.description.nil? || @contract &.con_id.to_s.to_i >= 0
			form action: R(ContractX, @account.account), method: 'post' do
				table do
			tr.exited do
				td( colspan:3, align:'left' ) { 'Contract-Mask' }
			end
					input_row['exchange', @contract &.contract_detail.present? ? @contract &.contract_detail.long_name : @contract&.to_human]
					input_row['symbol',  " market price : #{@contract &.misc}  (delayed)" ]
					input_row['currency', @contract &.con_id.to_s.to_i >0  ? " con-id : #{@contract &.con_id}" : '' ]
					input_row['expiry', @contract &.last_trading_day.present? ? " expiry: #{@contract &.last_trading_day}" : ''] if @contract.is_a?(IB::Future) || @contract.is_a?(IB::Option)
					input_row['right',   @contract.right ] if @contract.is_a?(IB::Option)  
					input_row['strike',  @contract.strike ] if @contract.is_a?(IB::Option)  
					input_row['multiplier', @contract &.multiplier.to_i >0  ? @contract &.multiplier : '']

					tr do
						td "Type"
						td do
							select( name: 'sec_type', size:1 ) do
								IB::Contract::Subclasses.each do |x,y| 
									@contract &.sec_type == x.to_sym ? option( selected: 'selected' ){ x } :  option( x ) 
								end  # each
							end		 # select
						end			 # td
						td { input :type => 'submit', :class => 'submit', :value => 'Verify' } unless @contract.is_a?(Symbol) || @contract &.con_id.to_s.to_i < 0
					end  # tr
				end	  # table
			end #form
		else
			table{ tr { td @contract &.to_human[1..-2] } } 
		end # if-branch
		_order_mask if @contract &.description.present? || @contract &.con_id.to_s.to_i != 0 
	end # contract_mask




	########   show Index ############# 
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
		@the_error_message
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

	## contracts ##
	def _contract(c)
		tr do
			td c.sec_type.to_s.upcase
			td c.symbol
			td c.currency
			td c.exchange
			td.number c.con_id
		end
	end
	def _link_to_close_contract( contract, con_id , cols:2)
			td(colspan:cols){ a  yield(contract.to_human[1..-2]), href: R(CloseContractXX  , @account.account, con_id.to_i ) }
	end

	## order ##
	def _order_attributes_and_submit

		the_price = -> { @contract.misc  || @contract.misc = @contract.market_price}  # holds the market price from the previous query
		tr do
			td '(Primary/Limit) Price :'
			td { input type: :text, value: @contract.misc, name: 'limit_price' };
			td( align: :right ){ '(Aux/Stop) Price  :' }
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

	def _pending_orders( columns ) 
		pending_orders = *yield 
			if pending_orders.empty?
				tr.exited { td( colspan: columns, align: 'center'){ 'No Pending-Orders' } }
			else
				tr.exited { td( colspan: columns, align:'left' ) { 'Pending-Orders' } }
				pending_orders.each {  |a| tr { _order(a)} }  
			end
	end

  def _order_mask
		form action: R(OrderXX, @account.account, @contract.con_id), method: 'post' do
			table do
				tr.exited do
					td( colspan: 4, align: 'left' ) { 'Order-Mask' }
				end
				tr do
					td 'Size'
					td { input type: :text, value: -contract_size( @account, @contract) , name: 'total_quantity' };
				end
				_order_attributes_and_submit
			end
		end
	end 

	def _order( o )
		my_price = -> do
			if o.limit_price.present? && !o.limit_price.to_f.zero?
				if o.aux_price.present? && !o.aux_price.to_f.zero?
					"@ #{ActiveSupport::NumberHelper.number_to_rounded(o.limit_price.to_f)} / #{ActiveSupport::NumberHelper.number_to_rounded(o.aux_price.to_f)} "
				else
					"@ " + ActiveSupport::NumberHelper.number_to_rounded(o.limit_price.to_f) 
				end
			elsif o.aux_price.present? && !o.aux_price.to_f.zero?
				"@ " + ActiveSupport::NumberHelper.number_to_rounded(o.aux_price.to_f) 
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
			td account_name gw.clients.detect{ |a| a.account == o.account }
			td character[]
			td o.contract.to_human[1..-2] || "no Contract Info saved"
			td "#{o.side} #{o.quantity}  #{ o.order_type } #{o.tif}"
			td my_price[]
			td o.order_states.map{|x| x.status }.join(';')
			td { a 'cancel' , href: R(OrderXX, o.account, o.local_id ) } if o.local_id >0 
		end
	end
  ## account + portfolio ##
	def _account_infos( a )
		tr do
			_account_value a.account_data_scan('NetLiquidation').first
			_account_value a.account_data_scan('InitMarginReq').first  
			_account_value a.account_data_scan('TotalCashValue').first
		end
	end 

	def _account_value( av )
		td(colspan:2) do
			unless av.nil? || av.key.nil?	
		       	av.key.to_s + ': ' + ActiveSupport::NumberHelper.number_to_currency( av.value, precision:0, unit: av.currency, format: '%n %u' ).to_s 
			end
		end
	end 

	def _portfolio_position(pp, prefix:'')
		the_multiplier = ->{ pp.contract.multiplier.nil? || pp.contract.multiplier.zero? ? 1: pp.contract.multiplier }
		tr do
			_link_to_close_contract( pp.contract, pp.contract.con_id, cols: pp.position.zero? ? 3 : 2){ |x| prefix + x  }
			td.number pp.position.to_i  unless pp.position.zero?
			td.number  ActiveSupport::NumberHelper.number_to_rounded( pp.average_cost / the_multiplier[] )
			td.number  ActiveSupport::NumberHelper.number_to_rounded( pp.market_price )
			td.number "%15.2f " % pp.market_value				
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
  #wrapper { margin: 3em auto; width: 700px; }
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
