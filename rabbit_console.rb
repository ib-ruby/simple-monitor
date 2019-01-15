#!/usr/bin/env ruby
### loads the ib-ruby environment 
### and starts an interactive shell
###
### 
### loads the startup-parameter of simple-monitor
### and allocates watchlists
### 
### Its main proposure: Managment of watchlists
### 
### The »received«-Hash is enabled and asseccible throught
### C.received
require 'bundler/setup'
require './simple_monitor' 
require 'bunny'
require './rabbit/gateway_ext'
require './rabbit/client'
include Ibo::Helpers

### RabbitClient connects to a fanout channel and handles messages for the management of watchlist-contents
class RabbitClient
  mattr_accessor :logger  ## borrowed from active_support
  mattr_accessor:current

	def initialize  host: , #mailout.halfgarten-capital.de',
									username: ,
									password: ,
									channels: [:HC],
									logger: nil
		watchlists = channels.map { |w| w.is_a?(Symbols)?  w : IB::Symbols.allocate_collection( w ) }
		
		
		self.logger  ||=  Logger.new(STDOUT)
		@connection = Bunny.new( host:  host,
														vhost: 'hc', 
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
		IB::Gateway.current.active_accounts.each do | account |
					rc= Client.new(account)
					c =  nil; contract.verify{| y | c =  y }
					puts "order: #{order.total_quantity}"
					the_size = rc.calculate_position order, c, focus
				
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


	def run
		gw =  IB::Gateway.current
		@queues.each do |watchlist, queue|

			logger.formatter = proc do |level, time, prog, msg|
				"#{time.strftime('%H:%M:%S')} #{msg}\n"
			end
			logger.info { "subscribing #{watchlist.inspect}" }
			queue.subscribe do |delivery_info, metadata, payload|
				# puts "Received #{JSON.parse(payload).inspect}"
				message = JSON.parse( payload)
				kind =  message.to_a.shift.shift
				if gw.check_connection   # ensure that the connection is operative 
					case kind
					when 'place', 'modify', 'reverse', 'close', 'preview'
						watchlist_symbol , raw_order = message[kind]
						begin 
							contract = watchlist[watchlist_symbol.to_sym]
						rescue IB::SymbolError => e
							logger.error {"Contract #{watchlist_symbol} not defined in #{watchlist.name}"}
							@response_exchange.publish( {gw.advisor.account => "Contract not defined, #{watchlist_symbol} NOT PLACED ", watchlist_symbol: watchlist_symbol}.to_json , routing_key: kind )
						else  # process if no exception is raised
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
						end
					when 'cancel'
						watchlist_symbol = message[kind]
						begin
							contract = watchlist[watchlist_symbol.to_sym]
						rescue IB::SymbolError
							@response_exchange.publish( {gw.advisor.account => "Symbol #{watchlist_symbol} not Member of Watchlist #{watchlist.name.split(':').last}"}.to_json , routing_key: kind )
						else	# if no exception was raised
							cancel_the_order contract
						end
					when "restart"
						logger.error { "restart detected but not handled jet" } 
						@response_exchange.publish( {gw.advisor.account => "Restart not implemented"}.to_json , routing_key: kind )
					when 'reset'
						watchlist.purge_collection
						logger.debug{ "Collection purged" }
						IB::Symbols.allocate_collection watchlist.name.split(":").last  # extract name from class
					when "add_contract"
						key, message = message[kind].to_a
						contract = gw.build_from_json(message)
						watchlist.add_contract key.to_sym, contract
						logger.info{ "added  #{key}: #{contract.to_human} to watchlist #{watchlist.name.split(':').last}"}

					when "change_default" 
						symbol = message[kind]
						begin
							contract =  watchlist.send message[kind].shift.to_sym
						rescue IB::SymbolError
							@response_exchange.publish( {gw.advisor.account => "Symbol #{watchlist_symbol} not Member of Watchlist #{watchlist.name.split(':').last}"}.to_json , routing_key: kind )
						else	# if no exception was raised
							size = message[kind].shift.to_i
							change_default_value_for watchlist, contract, size
						end	
					when "remove_contract"
						symbol = message[kind]
						logger.debug{ "symbol to be removed: #{symbol}"}
						watchlist.remove_contract symbol.to_sym
					when "ping"
							@response_exchange.publish(gw.advisor.to_json, routing_key: kind ) 
							gw.active_accounts.each{|a|	@response_exchange.publish(a.to_json, routing_key: kind ) }
					when 'pending_orders'
						pending_orders.each do |account|
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
						else
						logger.error{ "Command not recognized: #{kind}" }
					end		# case
				else
					logger.error  {"No Connection to TWS-Server"}

					@error_exchange.publish( {gw.advisor.account => "No Commection to TWS"}.to_json , routing_key: 'connection' )
				end # if check_connection
			end			# subscribe
   end
	end
end

	


class Array
  # enables calling members of an array, which are hashes by name
  # i.e
  #
  #  2.5.0 :006 > C.received[:OpenOrder].local_id  # instead of ...[:OpenOrder].map(&:local_id)
  #   => [16, 17, 21, 20, 19, 8, 7] 
  #   2.5.0 :007 > C.received[:OpenOrder].contract.to_human  
  #    => ["<Bag: IECombo SMART USD legs:  >", "<Stock: GE USD>", "<Stock: GE USD>", "<Stock: GE USD>", "<Stock: GE USD>", "<Stock: WFC USD>", "<Stock: WFC USD>"] 
  #
  # its included only in the console, for inspection purposes

  def method_missing(method, *key)
    unless method == :to_hash || method == :to_str #|| method == :to_int
      return self.map{|x| x.public_send(method, *key)}
    end

  end
end # Array


  puts 
  puts ">> R A B B I T – M O N I T O R  Interactive Console <<" 
  puts '-'* 45
  puts 
  puts "Namespace is IB ! "
  puts
 
  include IB
  require 'irb'
	d_host, d_client_id = read_tws_alias{|s| [ s[:host].present? ? s[:host] :'localhost', s[:client_id].present? ? s[:client_id] :0 ] } # client_id 0 gets any open order
  client_id =  d_client_id.zero? ? 0 : d_client_id-1
  ARGV.clear
  logger = Logger.new  STDOUT
  logger.formatter = proc do |level, time, prog, msg|
      "#{time.strftime('%H:%M:%S')} #{msg}\n"
	end
	logger.level = Logger::INFO 
		set_alias = ->(account) do 
			yaml_alias = read_tws_alias{ |s| s[:user][account.account]} 
			account.alias = yaml_alias if yaml_alias.present? && !yaml_alias.empty?
		end
 begin

		G =  Gateway.new  get_account_data: false, serial_array: true,
			client_id: client_id, host: d_host, logger: logger

		excluded_accounts = read_tws_alias(:exclude)
		excluded_accounts.keys.each{| a | G.for_selected_account(a.to_s){ |x| x.disconnect! }}	if excluded_accounts.present?
		set_alias[G.advisor]
		G.active_accounts.each { |a| set_alias[a]} 

		a = G.active_accounts.map{|x| Client.new x}
		watchlists = a.map{|b| b.read_defaults[:Anlageschwerpunkte].keys}.flatten.uniq
		G.get_account_data    watchlists: watchlists.map{|y| Symbols.allocate_collection y.to_sym}

	rescue IB::TransmissionError => e
		puts "E: #{e.inspect}"
	end
	C =  G.tws
  unless  C.received[:OpenOrder].blank?
    puts "------------------------------- OpenOrders ----------------------------------"
    puts C.received[:OpenOrder].to_human.join "\n"
  end
  puts  "Connection established on  #{d_host}, client_id #{client_id} used"
  puts
  puts  "----> G + C               point to the Gateway and the Connection -Instance"
	puts  "----> C.received          holds all received messages"
	puts  "----> G.active_accounts   points to gatherd account-data"
  puts	""
	puts	"Paramters from »read_tws_alias.yml« used"
  puts  "Simple-Monitor Helper Methods  are included!"
	puts  ""
	puts  "Allocated Watchlists:"
	puts  watchlists.map{|w| w.to_s}.join "\n"
  puts '-'* 45
	rabbit_credentials= read_tws_alias( :rabbit )
	error "No Rabbit credentials" if rabbit_credentials.nil? || rabbit_credentials.empty?
	puts "  Rabbit Reciever started"
	(R= RabbitClient.new(logger: logger, 
									 channels: watchlists, 
									 username: rabbit_credentials[:user],
									 password: rabbit_credentials[:password],
									 host: rabbit_credentials[:host])).run
  IRB.start(__FILE__)
