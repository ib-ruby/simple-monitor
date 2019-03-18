
### RabbitClient connects to a fanout channel and handles messages for the management of watchlist-contents
class  HCTR
  mattr_accessor :logger  ## borrowed from active_support
  mattr_accessor:current

	def initialize  host: , #mailout.halfgarten-capital.de',
									vhost: 'hc',
									username: ,
									password: ,
									channels: [:HC],
									logger: nil
		watchlists = channels.map { |w| w.is_a?(Symbols)?  w : IB::Symbols.allocate_collection( w ) }
		
		
		self.logger  ||=  Logger.new(STDOUT)
		@connection = Bunny.new( host:  host,
														vhost: vhost, 
															username: username, 
															password: password ,
															tls: true,
															tsl_cert: '../ssl/cert.pem',
															tsl_key: '../ssl/key.pem',
															tls_ca_certificate: ['../ssl/cacert.pem'],
															verify_peer:false 
													 )

		@connection.start
		channel =  @connection.create_channel
		@response_exchange = channel.direct("response") 
		order_subscription
		@error_exchange = channel.direct("error") 
		create_queue = -> { c= @connection.create_channel; c.queue('', exclusive: true) }
		@queues = watchlists.map do |ch|
	#		channel =  @connection.create_channel
	#		queue = channel.queue('', exclusive: true)a
			watchlist_name = ch.name.split(':').last.to_sym
			x = create_queue[].bind(watchlist_name)
			logger.debug{ "Found existing Exchange  #{watchlist_name} ... binding!" }
			[ch, x ]
		rescue Bunny::NotFound => e
			logger.warn e.inspect
			next
		end.compact

		@queues << [ "common",  create_queue[].bind('common')]
	  self #  make it chainable
	end




	def order_subscription # notify rabbit_console about any order
		IB::Gateway.current.tws.subscribe :OpenOrder do | msg |
					# make open order equal to IB::Spreads (include negativ con_id)
					msg.contract[:con_id] = -msg.contract.combo_legs.map{|y| y.con_id}.sum  if msg.contract.is_a? IB::Bag
					@response_exchange.publish( {msg.order.account =>  msg.order.serialize_rabbit}.to_json,
																															routing_key: 'open_order' )
				end
		end
	
	def pending_orders  ## Pending orders 
		IB::Gateway.current.update_orders				 # read pending_orders
		sleep 1
		IB::Gateway.current.active_accounts.map( &:orders ).flatten.compact
	end

	def return_calculated_position order, contract, focus
		contract_size = ->(a,c) do			# note: portfolio_value.position is either positiv or negativ
																		# note: nil.to_i ---> 0
			if c.con_id <0 # Spread
				p = a.portfolio_values.detect{|p| p.contract.con_id ==c.legs.first.con_id} &.position.to_i
				p / c.combo_legs.first.weight  unless p.zero?
			else
				a.portfolio_values.detect{|x| x.contract.con_id == c.con_id} &.position.to_i
			end
		end
		IB::Gateway.current.active_accounts.each do | account |
					actual_size =  contract_size[account,contract]
					if actual_size.nil? || actual_size.zero?
						rc= Client.new(account)
						the_size = rc.calculate_position order, contract, focus
					else
						the_size =  -(actual_size.abs)
					end
					@response_exchange.publish( {account.account => { contract: contract.serialize_rabbit, 
																														size: the_size }}.to_json , 
																		   routing_key: 'preview' )
		end
	end



	def place_the_order order, contract, focus
		IB::Gateway.current.tws.update_next_order_id
		IB::Gateway.current.active_accounts.each do | account |
			r = ->(l){ account.locate_order local_id: l, status: nil }
			ref_order = account.locate_order con_id: contract.con_id 
			serialized_contract= contract.serialize_rabbit
			if ref_order.present?
				modify_the_order order, contract
			else
				working_order =  IB::Order.duplicate order
				rc= Client.new(account)
				working_order.total_quantity = rc.calculate_position( order, contract, focus)
				puts "calculated quantity: #{working_order.total_quantity}"
				ref_position = account.portfolio_values.detect do |pv| 
					(contract.is_a?(IB::Spread) ?  pv.contract.con_id == contract.legs.first.con_id : pv.contract.con_id == contract.con_id ) && !pv.position.to_i.zero?
				end
				if ref_position.present?
				logger.error {"#{account.alias} -> Found existing position: #{ref_position.to_human}"	} 
				@error_exchange.publish( {account.account => { contract: serialized_contract, 
																									 message: "NOT PLACED, Detected exsting Position" }}.to_json , 
																									 routing_key: 'place' )
				elsif !working_order.total_quantity.zero? 
					working_order.contract =  contract    # do not verify further
					the_local_id = account.place order: working_order
					begin
						Timeout::timeout(1){ loop{  sleep 0.1;  break if  r[the_local_id] } }
						if r[the_local_id].status =~ /ject/ 
							@error_exchange.publish( {account.account => { contract: serialized_.contract, 
																											message: "order rejected" }}.to_json , 
																											routing_key: 'place' )
						else
							logger.info{ "#{account.alias} -> Order placed: #{working_order.action} #{working_order.total_quantity} @ #{order.limit_price} / #{order.aux_price} on #{contract.to_human}" }
				@response_exchange.publish( {account.account => { contract: serialized_contract, 
																									 message: "Order placed: #{working_order.action} #{working_order.total_quantity} @ #{order.limit_price} / #{order.aux_price} on #{contract.to_human}" }}.to_json , 
																									 routing_key: 'place' )
						end
					rescue Timeout::Error
						@error_exchange.publish( {account.account => { contract: serialized_contract, 
																										 message: "submitted order not returned by tws" }}.to_json , 
																										 routing_key: 'place' )
					end

				end # unless
			end   # branch
		end				# each
	end					# def

	def cancel_the_order  contract
		IB::Gateway.current.update_orders
		IB::Gateway.current.active_accounts.each do | account |
			order_to_cancel = account.locate_order con_id: contract.con_id 
			if order_to_cancel.is_a? IB::Order
				begin
					Timeout::timeout(3) do
						IB::Gateway.current.cancel_order order_to_cancel 
						loop  { sleep 0.1; break if !!(account.locate_order( local_id: order_to_cancel.local_id , status: /Cancel/))  }
					end

					@response_exchange.publish( {account.account => account.locate_order( 
																												 local_id: order_to_cancel.local_id , 
																												 status: /Cancel/).serialize_rabbit}.to_json , 
																		 routing_key: 'cancel-order' )
				 
				rescue Timeout::Error

					@error_exchange.publish( {account.account => "Cancelling of Order Local_id: #{order_to_cancel.local_id}  (Symbol: #{contract.symbol}) went possibly wrong."}.to_json , routing_key: 'cancel-order' )
				end
			end
		end
	end
	def modify_the_order order, contract
		IB::Gateway.current.update_orders
		IB::Gateway.current.active_accounts.each do | account |
				working_order =  IB::Order.duplicate order
				working_order.local_id = nil ## reset  local_id
				ref_order = account.locate_order con_id: contract.con_id
				if ref_order.present?
					order.contract =  contract
					working_order.local_id  = ref_order.local_id
					working_order.total_quantity = if order.total_quantity.zero?  # no change
																		ref_order.total_quantity
																 else 
																	 amount = (ref_order.total_quantity * order.total_quantity.abs).round
																	 if order.total_quantity < 0  # reduce
																		 ref_order.total_quantity - amount
																	 else
																		 ref_order.total_quantity + amount
																	 end
																 end
					working_order.modify	
				else
				 false
				end
		end
	end

	def return_contract_if_possible watchlist, symbol
		begin
			c =  watchlist.send symbol
		rescue IB::SymbolError
			@error_exchange.publish( {gw.advisor.account => "Contract #{sym} not found in watchlist #{watchlist.name}"}.to_json , routing_key: 'contract' )
		else
			@response_exchange.publish({gw.advisor => { contract: c} }.to_json, routing_key: 'contract') 
			IB::Gateway.current.active_accounts.each do | account |
				position = account.portfolio_values.find{|p| p.contract.con_id == c.verify!.con_id}
				if position
			@response_exchange.publish( {account.account => {:portfolio_value => position ,
																											 :contract => c.serialize_rabbit}}.to_json , routing_key: 'single_position' )
				else 
					puts "no position"
				end
			end

		end
	end
	def close_the_contract order, contract
		IB::Gateway.current.active_accounts.each do | account |
			nr = 0
			begin
			 account.close order: IB::Order.duplicate(order), contract: contract
			rescue IB::Error => e # no portfoliodata or contract not obtained
			@error_exchange.publish( {account.account => { contract: contract, message: e }}.to_json , routing_key: 'close-position' )
				logger.error e.inspect
				if nr.zero?
					nr = nr +1
					contract.verify!
					gw.get_account_data account
					resume 
				else
					raise
				end
			end

		end
	end

	def reverse_the_position order, contract
		IB::Gateway.current.active_accounts.each do | account |
			 account.close order: order, contract: contract, reverse: true
		end
	end


	def check_the_connection
			unless  gw.check_connection   # ensure that the connection is operative 
				logger.error  {"No Connection to TWS-Server"}
				@error_exchange.publish( {gw.advisor.account => "No Connection to TWS"}.to_json , routing_key: 'connection' )
				nil
			else
				true
			end 
	end


	def run
		gw =  IB::Gateway.current
		logger.formatter = proc do |level, time, prog, msg|
			"#{time.strftime('%H:%M:%S')} #{msg}\n"
		end
		@queues.each do |watchlist, queue|
			watchlist_symbol =  watchlist.is_a?( Module) ?  watchlist.name.split(':').last.to_sym 	: :HC
			logger.info { "subscribing #{watchlist.inspect}" }
			queue.subscribe do |delivery_info, metadata, payload|
#				puts "Received #{JSON.parse(payload).inspect}"
				message = JSON.parse( payload )
				kind =  message.to_a.shift.shift
				case kind

				when "add_contract"
					message = message[kind]
					key =  message.shift
					contract = gw.build_from_json(message.shift)
					watchlist.add_contract key.to_sym, contract
					logger.info{ "added  #{key}: #{contract.to_human} to watchlist #{watchlist_symbol}"}

				when "read_default"
					symbol = message[kind]
					IB::Gateway.current.active_accounts.each do | account |
						rc =  Client.new(account)
						@response_exchange.publish( { account.account => 
																			 [ symbol => rc.size(symbol)[watchlist_symbol] ] }.to_json, 
																			routing_key: kind  )
					end
				when "change_default", "set_default" 
							symbol = message[kind].shift.to_sym
							category, size = message[kind].first.first

							IB::Gateway.current.active_accounts.each do | account |
								rc= Client.new(account)
								if rc.category == category
									changed_size = 	if size.is_a?(String) && ["*",'+','-'].include?(size[0])
																		operation = size[0]
																		the_size =  size[1..-1].to_f
																		puts "ssymbol: #{symbol.inspect}"
																		puts "w_symbol: #{watchlist_symbol}"
																		org_size =  rc.size(symbol)[watchlist_symbol]
																		puts "orginial size: #{org_size}"
																		case operation
																		when "*"
																			org_size * the_size
																		when '+'
																			org_size + the_size
																		when '-' 
																			org_size - the_size
																		end
																	else
																		size.to_i
																	end.round
																	puts "changed_size: #{changed_size}"
									topic = rc.change_default(watchlist_symbol) {{ symbol => changed_size }} 

									@response_exchange.publish( {account.account => 
																			{ "#{category}/#{watchlist_symbol}" => topic}}.to_json,
																						 routing_key: 'change-default' )
								end
							end

				when "remove_symbol"   # R.{Watchlist} :remove_symbol, kategory, symbol
					symbol, category = message[kind]
					IB::Gateway.current.active_accounts.each do | account |
						rc= Client.new(account)
						if rc.category == category
							rc.remove_symbol watchlist_symbol, symbol  
							@response_exchange.publish( {account.account => 
																		{ "#{category}/#{watchlist_symbol}" => rc.read_defaults( :Anlageschwerpunkte)[ watchlist_symbol]}}.to_json,

																				routing_key: 'change-default' )
					end
			end
				when "restart"
					logger.error { "restart detected but not handled jet" } 
					@error_exchange.publish( {gw.advisor.account => "Restart not implemented"}.to_json,
																	routing_key: kind )
				when 'reset'
					watchlist.purge_collection
					logger.debug{ "Collection purged" }
					IB::Symbols.allocate_collection watchlist_symbol
				when "ping"
					if check_the_connection
						@response_exchange.publish(gw.advisor.to_json, routing_key: kind ) 
						gw.active_accounts.each{|a|	@response_exchange.publish(a.to_json, routing_key: kind ) }
					end
				when /pending/
					IB::Gateway.current.update_orders				 # read pending_orders and notify via Open-Orders
				when 'account-data', 'positions'
					gw.active_accounts.each do | account |
						gw.get_account_data account
						if kind == 'account-data'
							@response_exchange.publish({ account: account.account, 
																		values: account.account_values}.to_json, 
																		routing_key: kind )
						else
							transfer_object = account.portfolio_values.map{|y| { value: y}.merge  y.contract.serialize_rabbit }
							@response_exchange.publish({ account: account.account, 
																		values: transfer_object}.to_json, 
																		routing_key: kind )
						end
					end
				else  #  contract related signals
					contract_specification = message[kind].is_a?(Array) ?  message[kind].shift : message[kind]
					watchlist.read_collection  if watchlist.is_a?(Module)
					begin
						contract = if contract_specification =~ /^[0-9]+$/
												 gw.all_contracts.detect{|x| x.con_id == contract_specification.to_i}
											 else		
												 the_symbol = contract_specification.to_sym
												 watchlist[the_symbol] &.verify! &.essential  # early verification
											 end
					rescue NoMethodError =>e
						logger.error{ "Wrong message #{the_symbol}, #{message.inspect}" }
					rescue IB::SymbolError => e
						logger.error {"Contract #{the_symbol} not defined in #{watchlist.name}"}
						@error_exchange.publish( {gw.advisor.account => "Contract not defined", 
																watchlist: watchlist.name,
																symbol: the_symbol}.to_json , routing_key: 'contract' )
					else
						case kind
						when 'cancel'
							cancel_the_order contract
						when "remove_contract"
							logger.debug{ "symbol to be removed: #{the_symbol}"}
							watchlist.remove_contract watchlist_symbol
						when "contract?" 
							return_contract_if_possible watchlist, the_symbol
						when 'place', 'modify', 'reverse', 'close', 'preview'
							raw_order = message[kind].shift
							focus =  watchlist.name.split(':').last
							order = IB::Order.build_from_json(raw_order)
							case kind
							when 'modify'
								modify_the_order order, contract 
							when 'place'
								place_the_order order, contract, focus
							when 'reverse'
								reverse_the_position order, contract
							when 'close'
								close_the_contract order, contract
							when 'preview'
								puts "preview"
								return_calculated_position order, contract, focus
							end
						else
							logger.error{ "Command not recognized: #{kind}" }
						end	if check_the_connection	# case
					end  # begin rescze else end
				end # case
			end			# subscribe
		end
	end
end



