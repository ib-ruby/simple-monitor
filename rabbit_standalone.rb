
require 'bundler/setup'
require './simple_monitor' 
require 'bunny'
require './rabbit/gateway_ext'
require './rabbit/hctr'
require './rabbit/client'
include Ibo::Helpers


include IB

  logger = Logger.new  STDOUT
  logger.formatter = proc do |level, time, prog, msg|
      "#{time.strftime('%H:%M:%S')} #{msg}\n"
	end
	logger.level = Logger::INFO 
		set_alias = ->(account) do 
			yaml_alias = read_tws_alias{ |s| s[:user][account.account]} 
			account.alias = yaml_alias if yaml_alias.present? && !yaml_alias.empty?
		end

	d_host, d_client_id = read_tws_alias{|s| [ s[:host].present? ? s[:host] :'localhost', s[:client_id].present? ? s[:client_id] :0 ] } # client_id 0 gets any open order
  client_id =  d_client_id.zero? ? 0 : d_client_id-2
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


	rabbit_credentials= read_tws_alias( :rabbit )
	error "No Rabbit credentials" if rabbit_credentials.nil? || rabbit_credentials.empty?
	puts "  Rabbit Reciever started"
	(H= HCTR.new(logger: logger, 
									 channels: watchlists, 
									 username: rabbit_credentials[:user],
									 password: rabbit_credentials[:password],
									 vhost: 'test',   # production : 'hc'
									 host: rabbit_credentials[:host])).run
 
	ende = false
	t =  Thread.new do
				loop do 
					sleep 30
					break if !!ende
					print "sleepong"
				end
	end

	t.join
