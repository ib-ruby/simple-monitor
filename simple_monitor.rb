require 'bundler/setup'
require 'ib-gateway'
require 'camping'
require 'yaml'

Camping.goes :Ibo

module Ibo::Helpers
  def account_name account , allow_blank: false
		the_name = if File.exists?( 'tws_alias.yml') 
								 YAML.load_file('tws_alias.yml')[:user][account.account] rescue account.account
							 else 
								 account.alias  # alias is set to account-number if no alias is given
							 end
    allow_blank && ( the_name == account.account)  ? "" :	the_name.presence || account.account
  end
  def get_account account_id  # returns an account-object
    initialize_gw.active_accounts.detect{|x| x.account == account_id }
  end
  def initialize_gw 
    if IB::Gateway.current.nil?
      host = File.exists?( 'tws_alias.yml') ?  YAML.load_file('tws_alias.yml')[:host] : 'localhost' 
      gw= IB::Gateway.new( host: host, connect: true , client_id: 0, logger: Logger.new('simple-monitor.log') ) 
      gw.logger.level=1
      gw.logger.formatter = proc do |severity, datetime, progname, msg|
				"#{datetime.strftime("%d.%m.(%X)")}#{"%5s" % severity}->#{msg}\n"
      end
      gw.get_account_data.join
      gw.update_orders 
    end
    IB::Gateway.current # return_value
  end
  def all_contracts *sort
    sort = [ :sec_type ] if sort.empty?
    sort.map!{ |x| x.is_a?(Symbol) ? x : x.to_sym  }
		IB::Gateway.current.all_contracts.sort_by{|x| sort.map{|s| x.send(s)} } if IB::Gateway.current.present?
  end
end

module Ibo::Controllers
  class Index < R '/'
    def get
      initialize_gw
      render :show_account
    end
  end

  class StatusX
    def get action
      ib= initialize_gw  # make sure that everything is initialized
      account_data = -> {ib.get_account_data; ib.update_orders;  }
      rendered = false

      view_to_render = :show_account 
      case action.split('/').first.to_sym
			when :disconnect
				ib.disconnect if ib.tws.present?
			when :connect
				ib.connect
				account_data[]
			when :refresh
				account_data[]
			when :contracts
				account_data[]
				@accounts = ib.active_accounts
				view_to_render = :show_contracts
			end
			render view_to_render
		end

	end

  class SelectAccount # < R '/Status'
    def init_account_values	
      account_value = ->(item) do 
	array = @account.simple_account_data_scan(item).map{|y| [y.value,y.currency] unless y.value.to_i.zero? }.compact 
	array.sort{ |a,b| b.last == 'BASE' ? 1 :  a.last  <=> b.last } # put base element in front
      end
      @account_values= {  'Cash' =>  account_value['TotalCashBalance'],
                    'FuturesPNL' =>  account_value['PNL'],
                 'FutureOptions' =>  account_value['FutureOption'],
                       'Options' =>  account_value['OptionMarket'],
                        'Stocks' =>  account_value['StockMarket'] }
    end
    def get action
      @account = IB::Gateway.current.active_accounts.detect{|x| x.account == action.split('/').last }
      init_account_values
      render :show_account
    end

    def post 
			ib =  initialize_gw
      @account = ib.active_accounts.detect{|x| x.account == @input['account']}
      @contract = IB::Stock.new
      init_account_values
      render :contract_mask
    end
  end

  class ContractX # < R '/contract/(\d+)/select'
    def post account_id
      # if symbol is specified, search for the contract, otherwise use predefined contract
      @account =get_account account_id 
			@contract = if @input['symbol'].empty?
										@account.contracts.detect{|x| x.con_id == @input['predefined_contract'].to_i }
									else
										puts input.inspect
										@input[:right] = @input['right'][0].upcase if @input['sec_type']=='option'
										@input[:sec_type] = @input['sec_type'].to_sym
										IB::Contract.build @input.reject{|x| ['predefined_contract','right','sec_type'].include?(x) }
									end
      @contract.verify!
			@message = if @contract.nil? || @contract.con_id.to_i.zero?  
										 @contract ||= IB::Stock.new
										 "Not a valid contract, details in Log" 
									 else
										 ""
									 end
      @account.contracts.update_or_create( @contract  ) unless @contract.con_id.to_i.zero?
      render  :contract_mask
    end
  end

	class OrderXN 
		def get account_id, local_id
			account = get_account account_id 
			order = account.orders.detect{|x| x.local_id == local_id.to_i }
			IB::Gateway.current.cancel_order order.local_id if order.is_a? IB::Order
			sleep 1 

			redirect Index
		end
		def post account_id, con_id
			account =  get_account account_id 
			contract= account.contracts.detect{|x| x.con_id == con_id.to_i }
			puts "ORDER INPUT :: #{@input.inspect}"
			account.place_order order: IB::Order.new(@input), contract:contract
			redirect Index
		end
	end

 class Style < R '/styles\.css'
   STYLE = File.read(__FILE__).gsub(/.*__END__/m, '')
   def get
     @headers['Content-Type'] = 'text/css; charset=utf-8'
     STYLE
   end
 end

end # module controller

module Ibo::Views
	def layout
		html do
			head do
				title { "IB-Camping-Simple-Trading-Desk" }
				link :rel => 'stylesheet', :type => 'text/css', :href => '/styles.css', :media => 'screen'
			end
			show_index
			body { self << yield }
		end
	end

	def show_contracts
		size = ->(a,c){v= a.portfolio_values.detect{|x| x.contract == c }; v.present? ? v.position : "" }
		sleep 0.1  # wait for data to populate

		table do
			tr.exited do
				td { "Contracts" }
				@accounts.each{|a| td account_name(a) } if @accounts.present?
			end
			all_contracts( :sec_type, :symbol, :expiry,:strike ).each do | contract |
				tr do
					td contract.to_human[1..-2] 
					@accounts.each{|a| td size[a,contract] } if @accounts.present?
				end 
			end
			tr.exited do
				td( colspan: [@accounts.size+1,7].max ){ 'Pending-Orders' }
			end
			@accounts.each do |a|
				tr do
					if a.orders.present? 
						a.orders.each{|x| _order(x)} 
					else
						td account_name(a)
						td( colspan: @accounts.size ){ "No Pending Orders" }
					end
				end
			end
		end
	end

	def show_account
		table do
			if @account.present? && @account.account_values.present? 
				tr( class:  "lines") do
					td( colspan: 1) { @account.account }
					td( colspan: 3) { account_name  @account, allow_blank: true }
					td.number( colspan: 3){ "Last Update: #{@account.last_updated.strftime("%d.%m. %X")}" } 
					_account_infos(@account)
					if @account_values.present?
						@account_values.each{|y| _details(y) unless y.last.empty? }  #y ::["FuturesPNL", [["-255", "BASE"], ["-255", "EUR"]]]
					end
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
			tr.exited do
				td( colspan:8, align:'center' ) { 'Pending-Orders' }
			end
			IB::Gateway.current.for_active_accounts do |account|
				account.orders.each{|x| _order(x)} if account.orders.present?
			end
		end
	end

	def contract_mask
		input_row = ->( field , comment='' ) do
			tr { td( field.capitalize); td { input type: :text, value: @contract[field] , name: field }; td comment }
		end
		show_account
		form action: R(ContractX, @account.account), method: 'post' do
			table do
				tr.exited do
					td( colspan:3, align:'center' ) { 'Contract-Mask' }
				end
				tr { td( "Selected Account:" ); td( @account.account )}
				tr do
					td "Predefined Contracts: "
					td do 
						select( name: 'predefined_contract', size:1 ) do 
							@account.contracts.each do |x| 
								if @contract.con_id == x.con_id
									option( selected: 'selected',value: x.con_id){  x.to_human[1..-2] }
								else
									option( value: x.con_id){  x.to_human[1..-2] }
								end 
							end # each
						end # select
					end #td
					if @message.present?
						td @message
					else
						td { input :type => 'submit', :class => 'submit', :value => 'Use'  }
					end
				end
				input_row['symbol', '(if empty predefined Contract will be used)']
				input_row['currency', @contract.con_id.present? ? " con-id : #{@contract.con_id}" : '' ]
				input_row['exchange', @contract.contract_detail.present? ? @contract.contract_detail.long_name : '']
				input_row['expiry', @contract.contract_detail.present? ? @contract.contract_detail.industry : '']
				input_row['right', @contract.contract_detail.present? ? @contract.contract_detail.category : '']
				input_row['strike' ]
				input_row['multiplier']
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
		_order_mask if @contract.con_id.present?
	end # contract_mask

  def _order_mask
    form action: R(OrderXN, @account.account, @contract.con_id), method: 'post' do

      table do
	tr.exited do
	  td( colspan:6, align:'center' ) { 'Order-Mask' }
	end
	tr do
	  td
	  td { [ input( type: :radio, name: 'action' , value: 'buy', checked:'checked')  , '  Buy'].join }
	  td { [ input( type: :radio, name: 'action' , value: 'sell')  , '  Sell'].join }
	  td { [ input( type: :checkbox, value: 'true' , name: 'what_if')  , 'WhatIf'].join }
	  td { [ input( type: :checkbox, value: 'true' , name: 'transmit', checked:'checked')  , 'Transmit'].join }
	end
	tr do
	  td 'Size'
	  td { input type: :text, value: '' , name: 'total_quantity' };
	  td '(Limit) Price'
	  td { input type: :text, value: '' , name: 'limit_price' };
	  td '(Aux) Price'
	  td { input type: :text, value: '' , name: 'aux_price' };
	end
	tr do
	  td 'Order Type'
	  td { select( name: "order_type", size:1){ IB::ORDER_TYPES.each{ |a,b| option( value: a){ b } } } }
	  td 'Validity'
	  td { select( name: 'tif', size:1){[ "GTC", "DAY" ].each{|x| option x }} }
	  td { input :type => 'submit', :class => 'submit', :value => 'submit' }
	end
      end
    end
  end 

  def show_index
    form action: R(SelectAccount), method: 'post' do
      table  do
	tr do
	  td "TWS-Host: #{IB::Gateway.current.get_host}"
	  td "Status: #{status = IB::Gateway.tws.connected? ? 'Connected' : 'Disconnected'}"
	  if status =='Connected'
	    td 'Depot:'
	    td { select( :name => 'account', :size => 1){
			IB::Gateway.current.for_active_accounts{|x| option( :value => x.account){ account_name(x, allow_blank: false) } } } }
	    td { input :type => 'submit', :class => 'submit', :value => 'Select Account' }
	    td { a 'Contracts', href: R(StatusX, :contracts) }

	    td { a 'Refresh', href: R(StatusX, :refresh) }
	    td { a 'Disconnect', href: R(StatusX, :disconnect) }
	  else
	    td { a 'Connect', href: R(StatusX, :connect) } 
	  end # branch
	end # tr
      end # table
    end # form
  end # def

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

  def _order(o)
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
    td(colspan:2){ av.key.to_s + ': ' + 
     ActiveSupport::NumberHelper.number_to_currency( av.value, precision:0, unit: av.currency, format: '%n %u' ).to_s }
  end 

   def _portfolio_position(pp)
     tr do
         td(colspan:2){ pp.contract.to_human[1..-2] }
         td.number pp.position 
         td.number  ActiveSupport::NumberHelper.number_to_rounded( pp.average_cost )
         td.number  ActiveSupport::NumberHelper.number_to_rounded( pp.market_price )
         td.number  ActiveSupport::NumberHelper.number_to_delimited(ActiveSupport::NumberHelper.number_to_rounded(  pp.market_value, precision:0 ))
         if pp.realized_pnl.to_i.zero?
           td.number  ActiveSupport::NumberHelper.number_to_delimited(ActiveSupport::NumberHelper.number_to_rounded(  pp.unrealized_pnl, precision:0 ))
         else
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
