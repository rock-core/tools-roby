require 'roby'
require 'roby/distributed/drb'
require 'roby/distributed/objects'
require 'roby/distributed/protocol'

require 'roby/distributed/proxy'
require 'roby/distributed/connection_space'
require 'roby/distributed/notifications'
require 'roby/distributed/peer'
require 'roby/distributed/transaction'

module Roby
    def Distributed.component_name; 'distributed' end
    module Distributed::ApplicationConfig
	attribute(:discovery) { Hash.new }
	attribute(:droby) { Hash['period' => 0.5, 'max_errors' => 1] }

	def single?; super || discovery.empty? end

	def self.load(config, options)
	    config.load_option_hashes(options, %w{discovery droby})
	end

	def self.start(config, simulation)
	    return if config.single?

	    DRb.start_service "roby://#{config.droby['host']}"
	    droby_config = { :ring_discovery => !!config.discovery['ring'],
		:name => config.robot_name, 
		:plan => Roby::Control.instance.plan, 
		:max_allowed_errors => config.droby['max_errors'], 
		:period => config.droby['period'] }

	    if config.discovery['tuplespace']
		droby_config[:discovery_tuplespace] = DRbObject.new_with_uri("roby://#{config.discovery['tuplespace']}")
	    end
	    Roby::Distributed.state = Roby::Distributed::ConnectionSpace.new(droby_config)

	    if config.discovery['ring']
		Roby::Distributed.publish config.discovery['ring']
	    end
	    Roby::Control.every(config.droby['period']) do
		Roby::Distributed.state.start_neighbour_discovery
	    end
	end

	DISCOVERY_TEMPLATE = [:host, nil, nil, nil]
	def self.start_distributed(config)
	    if config.single? || !config.discovery['tuplespace']
		STDERR.puts "Centralized network discovery disabled, nothing to do"
		return
	    end

	    ts = Rinda::TupleSpace.new
	    DRb.start_service "roby://#{config.discovery['tuplespace']}", ts

	    new_db = ts.notify('write', DISCOVERY_TEMPLATE)
	    take_db = ts.notify('take', DISCOVERY_TEMPLATE)

	    Thread.start do
		new_db.each { |_, t| STDERR.puts "new host #{t[3]}" }
	    end
	    Thread.start do
		take_db.each { |_, t| STDERR.puts "host #{t[3]} has disconnected" }
	    end
	    STDERR.puts "Started service discovery on #{config.discovery['tuplespace']}"
	end

	def self.stop_distributed(config)
	    DRb.stop_service
	rescue Interrupt
	end
    end
end

