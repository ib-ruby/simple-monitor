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
include Ibo::Helpers

### RabbitClient connects to a fanout channel and handles messages for the management of watchlist-contents
class RabbitClient
  mattr_accessor :logger  ## borrowed from active_support
  mattr_accessor:current

	def initialize  host: 'omega', #mailout.halfgarten-capital.de',
									vhost: 'test',
									username: 'topo',
									password: 'focus',
									channels: [:HC],
									logger: nil
		watchlists = channels.map { |w| w.is_a?(Symbols)?  w : IB::Symbols.allocate_collection( w ) }
		
		
		self.logger  ||=  Logger.new(STDOUT)
		@connection = Bunny.new( host: host, vhost: vhost, username: username, password: password, logger: logger )

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
	


	def run
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
				when "restart"
					logger.error { "restart detected but not handled jet" } if message =={ 'restart' => true }
					@response_exchange.publish( {IB::Gateway.current.advisor.account => "Restart not implemented"}.to_json , routing_key: kind )
				when 'reset_watchlist'
					watchlist.purge_collection
					logger.debug{ "Collection purged" }
					IB::Symbols.allocate_collection watchlist.name.split(":").last  # extract name from class
				when "add_contract"
					key, message = message.to_a.shift.pop
					contract = if message.key?( 'Spread')
											 IB::Spread.build_from_json(message)
										 else
											 IB::Contract.build_from_json(message)
										 end
					watchlist.add_contract key.to_sym, contract
					logger.info{ "added  #{key}: #{contract.to_human} to watchlist #{watchlist.name.split(':').last}"}
				when "remove_contract"
					symbol = message['remove_contract']
					logger.debug{ "symbol to be removed: #{symbol}"}
					watchlist.remove_contract symbol.to_sym
				when "ping"
					puts "ping recognized from #{watchlist}"
					@response_exchange.publish(IB::Gateway.current.advisor.to_json, routing_key: kind )
					IB::Gateway.current.active_accounts.each{|a|	@response_exchange.publish(a.to_json, routing_key: kind )
  }
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
  puts ">> S I M P L E – M O N I T O R  Interactive Console <<" 
  puts '-'* 45
  puts 
  puts "Namespace is IB ! "
  puts
 
  include IB
  require 'irb'
	d_host, d_client_id = read_tws_alias{|s| [ s[:host].present? ? s[:host] :'localhost', s[:client_id].present? ? s[:client_id] :0 ] } # client_id 0 gets any open order
  client_id =  d_client_id.zero? ? 900 : d_client_id-1
  ARGV.clear
  logger = Logger.new  STDOUT
  logger.formatter = proc do |level, time, prog, msg|
      "#{time.strftime('%H:%M:%S')} #{msg}\n"
	end
	logger.level = Logger::INFO 

 begin
		G =  Gateway.new  get_account_data: true, serial_array: true,
			client_id: client_id, host: d_host, logger: logger,
			watchlists: read_tws_alias(:watchlist)
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

	puts "  Rabbit Reciever started"
	RabbitClient.new(logger: logger, channels: watchlists).run
  IRB.start(__FILE__)
