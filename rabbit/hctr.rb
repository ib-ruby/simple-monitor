
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
	
	def pending_orders
		IB::Gateway.current.update_orders				 # read pending_orders
		sleep 1
		IB::Gateway.current.active_accounts.map( &:orders ).flatten.compact
	end

	def change_default_value_for watchlist, contract, size
		IB::Gateway.current.active_accounts.each do | account |
					rc= Client.new(account)
					rc.change_default(watchlist.name.split(':').last) do | current |
						current[contract.symbol.to_sym] = size 
						current
					end
			end
	end
	def return_calculated_position order, contract, focus
		contract_size = ->(a,c) do			# note: portfolio_value.position is either positiv or negativ
			if c.con_id <0 # Spread
				p = a.portfolio_values.detect{|p| p.contract.con_id ==c.legs.first.con_id}.position.to_i
				p / c.combo_legs.first.weight  rescue 0  # rescue: if p.zero?
			else
				a.portfolio_values.detect{|x| x.contract.con_id == c.con_id} || 0
			end
		end


		IB::Gateway.current.active_accounts.each do | account |
					c =  nil; contract.verify{| y | c =  y }
					actual_size =  contract_size[account,c]
					puts "actual_size: #{actual_size}"
					if actual_size.zero?
						rc= Client.new(account)
						puts "order: #{order.total_quantity}"
						the_size = rc.calculate_position order, c, focus
					else
						the_size =  -(actual_size.abs)
					end
					@response_exchange.publish( {account.account => { contract: contract.serialize_rabbit, size: the_size }}.to_json , routing_key: 'preview' )
		end
	end
	def place_the_order order, contract, focus
		
		c =  nil; contract.verify{| y| c =  y }
		IB::Gateway.current.active_accounts.each do | account |
				ref_order = account.orders.detect{|x| x.contract.con_id == c.con_id && x.status =~ /ubmitted/}
				if ref_order.present?
					modify_the_order order, c
				else
					working_order =  IB::Order.duplicate order
					rc= Client.new(account)
					working_order.total_quantity = rc.calculate_position( order, c, focus)

					ref_position = account.portfolio_values.detect do |pv| 
						 c.is_a?(IB::Spread) ?  pv.contract.con_id == c.legs.first.con_id : pv.contract.con_id == c.con_id 
					end
				puts "Found existing position: #{ref_position.to_human}"	  if ref_position.present?
					unless working_order.total_quantity.zero? || ref_position.present?
					  working_order.contract =  c    # do not verify further
						account.place order: working_order
						logger.info{ "#{account.alias} -> Order placed: #{working_order.action} #{working_order.total_quantity} @ #{order.limit_price} / #{order.aux_price} on #{c.to_human}" }
					end
				end
		end
	end

	def cancel_the_order  contract
		IB::Gateway.current.update_orders
		IB::Gateway.current.active_accounts.each do | account |
				IB::Gateway.current.cancel_order *account.orders.find_all{|x| x.contract.symbol == contract.symbol && x.status =~ /ubmitted/}
			end
	 end



	def modify_the_order order, contract
		IB::Gateway.current.update_orders
		c=  nil; contract.verify { |y| c=  y } 
		IB::Gateway.current.active_accounts.each do | account |
				working_order =  IB::Order.duplicate order
				working_order.local_id = nil ## reset  local_id
				ref_order = account.orders.detect{|x| x.contract.con_id == c.con_id && x.status =~ /ubmitted/}
				if ref_order.present?
					order.contract =  c
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

	def close_the_contract order, contract
		IB::Gateway.current.active_accounts.each do | account |
			 account.close order: IB::Order.duplicate(order), contract: contract
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
				@error_exchange.publish( {gw.advisor.account => "No Commection to TWS"}.to_json , routing_key: 'connection' )
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

			logger.info { "subscribing #{watchlist.inspect}" }
			queue.subscribe do |delivery_info, metadata, payload|
				# puts "Received #{JSON.parse(payload).inspect}"
				message = JSON.parse( payload )
				kind =  message.to_a.shift.shift
				case kind

				when "add_contract"
					key, message = message[kind].to_a
					contract = gw.build_from_json(message)
					watchlist.add_contract key.to_sym, contract
					logger.info{ "added  #{key}: #{contract.to_human} to watchlist #{watchlist.name.split(':').last}"}

				when "restart"
					logger.error { "restart detected but not handled jet" } 
					@error_exchange.publish( {gw.advisor.account => "Restart not implemented"}.to_json , routing_key: kind )
				when 'reset'
					watchlist.purge_collection
					logger.debug{ "Collection purged" }
					IB::Symbols.allocate_collection watchlist.name.split(":").last  # extract name from class
				when "ping"
					if check_the_connection
						@response_exchange.publish(gw.advisor.to_json, routing_key: kind ) 
						gw.active_accounts.each{|a|	@response_exchange.publish(a.to_json, routing_key: kind ) }
					end
				when /pending/
					pending_orders.each do |account|
						puts "pending order for #{account.alias}"
						@response_exchange.publish( { account: account.account, 
																		order:  account.serialize_rabbit}.to_json,
																		routing_key: kind )
					end
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
					watchlist_symbol = message[kind].is_a?(Array) ?  message[kind].shift : message[kind]
					begin
						contract = watchlist[watchlist_symbol.to_sym]
					rescue IB::SymbolError => e
						logger.error {"Contract #{watchlist_symbol} not defined in #{watchlist.name}"}
						@error_exchange.publish( {gw.advisor.account => "Contract not defined", 
																watchlist: watchlist.name,
																symbol: watchlist_symbol}.to_json , routing_key: 'contract' )
					else
						case kind
						when 'cancel'
							cancel_the_order contract
						when "change_default" 
							size = message[kind].shift.to_i
							change_default_value_for watchlist, watchlist_symbol.to_sym, size
						when "remove_contract"
							logger.debug{ "symbol to be removed: #{watchlist_symbol}"}
							watchlist.remove_contract watchlist_symbol.to_sym
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



