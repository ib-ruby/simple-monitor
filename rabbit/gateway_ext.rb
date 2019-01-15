module IB

	class Order
			using IBSupport


		def serialize_rabbit
			{ 'Contract' => contract.present? ?  contract.serialize( :option, :trading_class ) : '' ,
			  'Order' =>  self,
			  'OrderState' => order_state}
		end

		def self.build_from_json container
			the_order = IB::Order.new container['Order']
			the_order.contract = IB::Contract.build_from_json container unless container['Contract'].blank?
			the_order.order_state =  OrderState.new container['OrderState'] unless container['OrderState'].blank?
			the_order #  return_value
		end

		def self.duplicate another_order
			o = IB::Order.new another_order.attributes
			o.conditions =  another_order.conditions
			o.order_states =  another_order.order_states
			o.leg_prices = another_order.leg_prices
			o.algo_params = another_order.algo_params
			o.combo_params= another_order.combo_params
			o
		end
	end
	class Contract
			using IBSupport

		
		def serialize_rabbit
			{ 'Contract' => serialize( :option, :trading_class ) }
		end

		def self.build_from_json container
			 IB::Contract.build( container['Contract'].read_contract)
		end
	end


	class Account
		def net_liquidation
			simple_account_data_scan( /NetLiquidation$/).pop.value.to_f
		end
		alias buchwert net_liquidation 


		def present_position contract

		end
	end


	class Spread
			using IBSupport

		def serialize_rabbit
			{ "Spread" => serialize( :option, :trading_class ),
				'legs' => legs.map{ |y| y.serialize :option, :trading_class }, 'combo_legs' => combo_legs.map(&:serialize),
				'misc' => [description]
			}	
		end
		def self.build_from_json container
			read_leg = ->(a) do 
				  IB::ComboLeg.new :con_id => a.read_int,
                           :ratio => a.read_int,
                           :action => a.read_string,
                           :exchange => a.read_string

			end
			object= self.new  container['Spread'].read_contract

			object.legs = container['legs'].map{|x| IB::Contract.build x.read_contract}
			object.combo_legs = container['combo_legs'].map{ |x| read_leg[ x ] } 
			object.description = container['misc'].read_string
			object

		end

	end

	class Gateway

		def active_watchlists
		 @watchlists
		end
		def build_from_json container
			if container.key?('Spread')
				IB::Spread.build_from_json container
			elsif  container.key?('Contract')
				IB::Contract.build_from_json container
			elsif container.key?('Order')
				IB::Order.build_from_json container
			end
		end

	end
end
