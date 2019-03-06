class Client
	# Handles default-parameters provided by a yaml-file, which is maintained by the customer
	#
	# 
	# Its initialized with an IB::Account
	# 
	# The yaml file is named with the account-id 
	#
	def initialize account
		@account = account
		@yaml = nil
	end

	def filename
		
		dir = Pathname.new File.expand_path("../../clients", __FILE__ ) 
		dir + "#{@account.account}.yml"
	end
	def read_defaults key= :all  # access to yaml-config-file is cached. 
		# a block has access to the raw-structure
		make_default if  @yaml.nil? &&  !File.exists?(filename) 
		@yaml ||= YAML.load_file(filename) 
		if block_given?
			yield 	key.to_sym  == :all ? @yaml : @yaml[key.to_sym]
		else
			key.to_sym  == :all ? @yaml.dup  : @yaml[key.to_sym].dup
		end
	end


	#   topic =  :Trend
	# 	the_client.change_default( topic ){ {:ZN => 3 }}    <== add or change an item
	# 	or
	# 	content = {:Ratio=>0.3, :J36=>0, :GE=>0, :NEU=>10, :ZN=>3}
	# 	the_client.change_default( topic ){  content }     == overwrite   
	def change_default topic
		unmodified_defaults =  read_defaults[:Anlageschwerpunkte][topic.to_sym]
		@yaml[ :Anlageschwerpunkte ][ topic.to_sym ].merge! yield( unmodified_defaults )
		filename.open( 'w' ){|f| f.write @yaml.to_yaml}
		@yaml[ :Anlageschwerpunkte ][ topic.to_sym ]	 #  return complete topic
	end

	def remove_symbol topic, symbol
		read_defaults if @yaml.nil?
		@yaml[:Anlageschwerpunkte][topic.to_sym] &.delete symbol.to_sym
		filename.open( 'w' ){|f| f.write @yaml.to_yaml}
	end


	def category
		read_defaults[:Kategorie] &.upcase || "100K"
	end
	def make_default
		y = { Konto:{ ID: @account.account, alias: @account.alias },
				Absicht: 'langfristiger Kapitalaufbau',
				Anlageschwerpunkte: { BuyAndHold: {  Ratio: 0.6,
																				     BXB: 0 },
															Trend: { Ratio: 0.3,  J36: 0 },
															Hedge: { Ratio: 0.1, ZN: 0, ZB: 0, NQ: 0, ES: 0 },
															Currency: { Ratio: 0.5, JPY: 0 } ,
															Stillhalter: { Ratio: 0.4 , DAI: 6 },
															Spreads: { Ratio: 0,  
																				ESTX50: 1 ,  
																				ES: 0,
																				SPX: 0,  
																				HSI: 1, 
																				AP: 1  },
															Bond: { Ratio: 0.7, FAX: 0, ZN: 1, ZB: 0, GBL: 1, BTP: 0 } 
															}
				}

		filename.open( 'w' ){|f| f.write y.to_yaml}
	end

	# returns a hash with sizes
	#  size(:Ratio) 
	#  --> => {:BuyAndHold=>0.6, :Trend=>0.3, :Hedge=>0.1, :Currency=>0.5, :Stillhalter=>0.4, :Spreads=>0.4, :Bond=>0.7}
	#  size 'GE'
	#   => {:Trend=>0} 
	def size symbol
		read_defaults( :Anlageschwerpunkte ) do | y |
			y.map{|y,x| [y , x[symbol.to_sym] ] if x[symbol.to_sym].present?}.compact.to_h
		end
	end

	def calculate_position order,contract, focus 	#  returns the calculated position size
#		round_capital = ->(z){ z.round -((z.to_i.to_s.size) -2) }
		round_capital = ->(z){ z.round -(Math.log10(z).to_i)+1 }  # just the first two digits, rest "0"
		return(0) if 	 read_defaults( :Anlageschwerpunkte )[focus.to_sym].nil?

		size =  read_defaults( :Anlageschwerpunkte )[focus.to_sym][contract.symbol.to_sym] || 0
		
		if size == -1 
			#  automatic determination
			ratio= size(:Ratio)[focus.to_sym]
			return(0) if ratio.nil? || ratio.zero?  # ratio 0 --> only discret amounts allowed
			quantity =   order.total_quantity.to_f.zero? ? 1 : order.total_quantity
			max_capital = round_capital[ @account.net_liquidation * ratio * quantity]
			max_capital =  max_capital / contract.multiplier unless contract.multiplier.to_i.zero?
			price =  order.limit_price.presence ||  order.aux_price
			min_size =  if price < 5
										1000
									elsif price < 50
										100
									elsif price < 100
										50
									elsif price < 300
										10
									else
										1
									end

			((	( max_capital / price ) / min_size ) *  min_size).to_i
		else
			order.total_quantity.to_f.zero? ? size : ( order.total_quantity.to_f * size ).round
		end

#		ratio = 
#		order.total_quantity = (size(order.symbol) * ratio).round
	end
end

