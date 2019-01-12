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
	def read_defaults key= :all  # access to yaml-config-file is not cached. Changes
		# take effect immediately after saving the yaml-dataset
		# a block has access to the raw-structure
		make_default unless  File.exists?(filename) 
		structure = YAML.load_file(filename) 
		if block_given? && !!structure
			yield structure
		else
		key.to_sym  == :all ? structure  : structure[key.to_sym]
		end
	end

	def change_default topic
		modified_defaults = yield read_defaults[:Anlageschwerpunkte][topic.to_sym]
		the_new_defaults =  read_defaults 
		the_new_defaults[ :Anlageschwerpunkte][topic.to_sym] = modified_defaults
		filename.open( 'w' ){|f| f.write the_new_defaults.to_yaml}
	end
	def categories

					 	 { IB::Option =>  :Optionsstrategie,
							 IB::Future =>  :Future,
							 IB::FutureOption => :Optionsstrategie,
						   IB::Spread => :Optionsstrategie }
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

	def size contract # dev.
			read_defaults( :Anlageschwerpunkte )[contract.misc.to_sym][contract.symbol.to_sym] || 0
	end

	def calculate_position order,contract, focus 	#  returns the calculated position size
#		round_capital = ->(z){ z.round -((z.to_i.to_s.size) -2) }
		round_capital = ->(z){ z.round -(Math.log10(z).to_i)+1 }  # just the first two digits, rest "0"
		return(0) if 	 read_defaults( :Anlageschwerpunkte )[focus.to_sym].nil?

		size =  read_defaults( :Anlageschwerpunkte )[focus.to_sym][contract.symbol.to_sym] || 0
		
		if size == -1 
			#  automatic determination
			ratio= read_defaults( :Anlageschwerpunkte )[focus.to_sym][:Ratio]
			return(0) if ratio.nil?

			max_capital = round_capital[ @account.net_liquidation * ratio ]
			max_capital = order.total_quantity.to_f.zero? ? max_capital : order.total_quantity.to_f * max_capital
			price =  order.limit_price.presence ||  order.aux_price
			min_size =  if price < 5
										1000
									elsif price < 10
										500
									elsif price < 50
										100
									elsif price < 85
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

