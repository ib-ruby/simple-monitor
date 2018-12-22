module IB
	class Contract
			using IBSupport

		
		def serialize_rabbit
			{ 'Contract' => serialize( :option, :trading_class ) }
		end

		def self.build_from_json container
			IB::Contract.build container.values.first.read_contract

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

		def build_from_json container
			if container.key?('Spread')
				Spread.build_from_json container
			elsif  container.key?('Contract')
				IB::Contract.build container
			elsif container.key?('Order')
				IB::Order.new container
			end
		end

	end
end
