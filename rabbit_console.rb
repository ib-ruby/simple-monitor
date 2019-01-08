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
		IB::Gateway.current.active_accounts.each do | account |
				c =  nil; contract.verify{| y| c =  y }
				ref_order = account.orders.detect{|x| x.contract.con_id == c.con_id && x.status =~ /ubmitted/}
				if ref_order.present?
					modify_the_order order, c
				else
					rc= Client.new(account)
					rc.calculate_position order, c, focus
					unless order.total_quantity.zero? 
					  order.contract =  c
						account.place order: order
						logger.info{ "Order placed: #{order.to_human}" }
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
		IB::Gateway.current.active_accounts.each do | account |
				order.local_id = nil ## reset  local_id
				c=  nil; contract.verify { |y| c=  y } 
				ref_order = account.orders.detect{|x| x.contract.con_id == c.con_id && x.status =~ /ubmitted/}
				if ref_order.present?
					order.contract =  c
					order.local_id  = ref_order.local_id
					order.total_quantity = if order.total_quantity.zero?  # no change
																		ref_order.total_quantity
																 else 
																	 amount = (ref_order.total_quantity * order.total_quantity.abs).round
																	 if order.total_quantity < 0  # reduce
																		 ref_order.total_quantity - amount
																	 else
																		 ref_order.total_quantity + amount
																	 end
																 end
					order.modify	
				else
				 false
				end
		end
	end

	def close_the_contract order, contract
		IB::Gateway.current.active_accounts.each do | account |
			 order.local_id = nil ## reset  local_id
			 account.close order: order, contract: contract
		end
	end

	def reverse_the_position order, contract
		IB::Gateway.current.active_accounts.each do | account |
			 order.local_id = nil ## reset  local_id
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
				case kind
				when 'place', 'modify', 'reverse', 'close', 'preview'
					puts "place"
					watchlist_symbol , order = message[kind]
					begin 
						contract = watchlist[watchlist_symbol.to_sym]
					rescue IB::SymbolError => e
						logger.error {"Contract #{watchlist_symbol} not defined in #{watchlist.name}"}
						@response_exchange.publish( {gw.advisor.account => "Contract not defined, #{watchlist_symbol} NOT PLACED ", watchlist_symbol: watchlist_symbol}.to_json , routing_key: kind )
					else  # process if no exception is raised
						order = IB::Order.build_from_json(order)
						case kind
						when 'modify'
							modify_the_order order, contract 
						when 'place'
							focus =  watchlist.name.split(':').last
							place_the_order order, contract, focus
						when 'reverse'
							reverse_the_position order, contract
						when 'close'
							close_the_contract order, contract
						when 'preview'
							focus =  watchlist.name.split(':').last
							return_calculated_position order, contract, focus
						end
					end
				when 'cancel'
					watchlist_symbol = message[kind]
					puts "#{kind}: recognized #{watchlist_symbol}"
					begin
						contract = watchlist[watchlist_symbol.to_sym]
					rescue IB::SymbolError
						@response_exchange.publish( {gw.advisor.account => "Symbol #{watchlist_symbol} not Member of Watchlist #{watchlist.name.split(':').last}"}.to_json , routing_key: kind )
					else	# if no exception was raised
							cancel_the_order contract
					end
				when "restart"
					logger.error { "restart detected but not handled jet" } if message =={ 'restart' => true }
					@response_exchange.publish( {gw.advisor.account => "Restart not implemented"}.to_json , routing_key: kind )
				when 'reset'
					watchlist.purge_collection
					logger.debug{ "Collection purged" }
					IB::Symbols.allocate_collection watchlist.name.split(":").last  # extract name from class
				when "add_contract"
					key, message = message[kind].to_a
					contract = if message.key?( 'Spread')
											 IB::Spread.build_from_json(message)
										 else
											 IB::Contract.build_from_json(message)
										 end
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
					## Ping antwortet mit einer Liste von Usern (+ Advisor), jeweils als separate Message
					@response_exchange.publish(gw.advisor.to_json, routing_key: kind )
					gw.active_accounts.each{|a|	@response_exchange.publish(a.to_json, routing_key: kind ) }
				when 'pending_orders'
					pending_orders.each do |account|
						@response_exchange.publish( { account: account.account, 
																					order:  account.serialize_rabbit}.to_json,
																			  routing_key: kind )
					end
				when 'account-data'
					gw.active_accounts.each do | account |
						gw.get_account_data account
						@response_exchange.publish({ account: account.account, 
																	 values: account.account_values}.to_json, 
																	 routing_key: kind )
					end
				when 'positions'
					gw.active_accounts.each do | account |
						gw.get_account_data account
						transfer_object = account.portfolio_values.map{|y| { value: y}.merge  y.contract.serialize_rabbit }
					@response_exchange.publish({ account: account.account, 
																	values: transfer_object}.to_json, 
																	routing_key: kind )
					end
				else
					logger.error{ "Command not recognized: #{kind}" }
				end		# case
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
		G =  Gateway.new  get_account_data: true, serial_array: true,
			client_id: client_id, host: d_host, logger: logger,
			watchlists: read_tws_alias(:watchlist)

		excluded_accounts = read_tws_alias(:exclude)
		excluded_accounts.keys.each{| a | G.for_selected_account(a.to_s){ |x| x.disconnected! }}	if excluded_accounts.present?
		set_alias[G.advisor]
		G.active_accounts.each { |a| set_alias[a]} 

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
	puts "  Rabbit Reciever started"
	(R= RabbitClient.new(logger: logger, 
									 channels: watchlists, 
									 username: rabbit_credentials[:user],
									 password: rabbit_credentials[:password],
									 host: rabbit_credentials[:host])).run
  IRB.start(__FILE__)
