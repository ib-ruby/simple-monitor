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
require './rabbit/hctr'
require './rabbit/client'
include Ibo::Helpers


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
	d_host, d_client_id = read_tws_alias{|s| [ s[:host] || 'localhost', s[:client_id].to_i ] } # client_id 0 gets any open order
  client_id =  d_client_id.zero? ? 0 : d_client_id-1
  ARGV.clear
  logger = Logger.new  STDOUT
  logger.formatter = proc do |level, time, prog, msg|
      "#{time.strftime('%H:%M:%S')} #{msg}\n"
	end
	logger.level = Logger::INFO 

	set_alias = ->(account) do 
		yaml_alias = read_tws_alias{ |s| s[:user][account.account]} 
		account.update_attribute :alias , yaml_alias if  yaml_alias.present?
	end
 begin

		G =  Gateway.new  get_account_data: false, serial_array: true,
			client_id: client_id, host: d_host, logger: logger

		excluded_accounts = read_tws_alias(:exclude)
		excluded_accounts &.keys &.each{| a | G.for_selected_account(a.to_s){ |x| x.disconnect! }}		
		set_alias[G.advisor]
		G.active_accounts.each { |a| set_alias[a]} 

		clients = G.active_accounts.map{|x| Client.new x}
		watchlists = clients.map{|b| b.read_defaults[:Anlageschwerpunkte].keys}.flatten.uniq
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
  puts  "Simple-Monitor Helper Methods  are included!"
	puts  ""
	puts  "Allocated Watchlists:"
	puts  watchlists.map{|w| w.to_s}.join "\n"
  puts '-'* 45
	rabbit_credentials= read_tws_alias( :rabbit )
	error "No Rabbit credentials" if rabbit_credentials.nil? || rabbit_credentials.empty?
	puts "  Rabbit Reciever started"
	(H= HCTR.new(logger: logger, 
									 channels: watchlists, 
									 username: rabbit_credentials[:user],
									 password: rabbit_credentials[:password],
									 vhost: 'hc',   # production
									 host: rabbit_credentials[:host])).run
  IRB.start(__FILE__)
