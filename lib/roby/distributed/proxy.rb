require 'roby'
require 'roby/distributed/protocol'
module Roby
    module Distributed
	@@proxy_model = Hash.new

	# Builds a remote proxy model for +object_model+. +object_model+ is
	# either a string or a class. In the first case, it is interpreted
	# as a constant name.
	def self.RemoteProxyModel(object_model)
	    @@proxy_model[object_model] ||= 
		if object_model.has_ancestor?(Roby::Task)
		    Class.new(object_model) { include TaskProxy }
		elsif object_model.has_ancestor?(Roby::EventGenerator)
		    Class.new(object_model) { include EventGeneratorProxy }
		else
		    raise TypeError, "no proxy for #{object_model}"
		end
	end

	module RemoteObjectProxy
	    # The marshalled object
	    attr_reader :marshalled_object
	    def distribute?; true end

	    def initialize_remote_proxy(peer, marshalled_object)
		unless marshalled_object.model.ancestors.find { |klass| klass == self.class.superclass }
		    raise TypeError, "invalid remote task type. Was expecting #{self.class.superclass.name}, got #{marshalled_object.model.ancestors}"
		end

		@marshalled_object = marshalled_object
		owners.clear
		owners << peer
		remote_siblings[peer] = marshalled_object.remote_object
	    end

	    def model; self.class.superclass end
	    module ClassExtension
		def name; "dProxy(#{super})" end
	    end
	    def droby_dump; marshalled_object.remote_object end
	end

	module EventGeneratorProxy
	    include RemoteObjectProxy

	    def initialize(peer, marshalled_object)
		initialize_remote_proxy(peer, marshalled_object)
		super()
	    end
	    def initialize_remote_proxy(peer, marshalled_object)
		super
		@happened	 = marshalled_object.happened

		if marshalled_object.controlable
		    self.command = lambda {}
		end
	    end
	    def happened?; @happened || super end
	end

	module TaskEventGeneratorProxy
	    include EventGeneratorProxy
	end

	module TaskProxy
	    include RemoteObjectProxy
	    def initialize(peer, marshalled_object)
		initialize_remote_proxy(peer, marshalled_object)
		super(marshalled_object.arguments) do
		    Roby::Distributed.updated_objects << self
		end

		@name << "@#{peer.remote_name}"
	    rescue ArgumentError
		raise $!, $!.message + " (#{self.class.ancestors[1..-1]})", $!.backtrace
	    ensure
		Roby::Distributed.updated_objects.delete(self)
	    end
	end

	# Base class for all marshalled plan objects.
	class MarshalledPlanObject
	    def to_s; "m(#{remote_name})" end
	    attr_reader :remote_name, :remote_object, :model, :plan
	    def initialize(remote_name, remote_object, model, plan)
		@remote_name, @remote_object, @model, @plan = 
		    remote_name, remote_object, model, plan
	    end

	    def self.droby_load(str)
		data = Marshal.load(str)
		object  = data[1]		    # the remote object
		yield(data)
	    end

	    def marshal_format
		[remote_name, remote_object,
		    Distributed.format(model),
		    Distributed.format(plan)]
	    end
	    def _dump(lvl)
		Marshal.dump(marshal_format) 
	    end

	    # Creates the local object for this marshalled object
	    def proxy(peer)
		local_object = Distributed.RemoteProxyModel(model).new(peer, self)
		local_object.sibling_of(remote_object, peer)
		local_object
	    end

	    # Updates the status of the local object if needed
	    def update(peer, proxy)
		if self.plan
		    plan = peer.local_object(self.plan)
		    Distributed.update([plan, proxy]) do
			plan.discover(proxy)
		    end
		end
	    end
	end

	class Roby::EventGenerator
	    def droby_dump
		MarshalledEventGenerator.new(to_s, drb_object, self.model, plan, controlable?, happened?)
	    end
	end
	class MarshalledEventGenerator < MarshalledPlanObject
	    def self._load(str)
		droby_load(str) do |data|
		    if block_given? then yield(data)
		    else new(*data)
		    end
		end
	    end
	    def marshal_format; super << controlable << happened end

	    def update(peer, proxy)
		if happened && !proxy.happened?
		    proxy.instance_eval { @happened = true }
		end
	    end

	    attr_reader :controlable, :happened
	    def initialize(remote_name, remote_object, model, plan, controlable, happened)
		super(remote_name, remote_object, model, plan)
		@controlable, @happened = controlable, happened
	    end
	end

	class Roby::TaskEventGenerator
	    def droby_dump
		# no need to marshal the plan, since it is the same than the event task
		MarshalledTaskEventGenerator.new(to_s, drb_object, self.model, nil, controlable?, happened?, task, symbol)
	    end
	end
	class MarshalledTaskEventGenerator < MarshalledEventGenerator
	    attr_reader :task, :symbol
	    def initialize(name, remote_object, model, plan, controlable, happened, task, symbol)
		super(name, remote_object, model, plan, controlable, happened)
		@task   = task
		@symbol = symbol
	    end

	    def self._load(str)
		super do |data|
		    new(*data)
		end
	    end
	    def marshal_format; super << Distributed.format(task) << symbol end

	    def proxy(peer)
		task = peer.local_object(self.task)
		return unless task.has_event?(symbol)
		ev   = task.event(symbol)

		if task.kind_of?(RemoteObjectProxy) && !ev.kind_of?(TaskEventGeneratorProxy)
		    ev.extend TaskEventGeneratorProxy
		    ev.initialize_remote_proxy(peer, self)
		end

		ev.remote_siblings[peer] = remote_object
		ev
	    end
	end

	class Roby::Task
	    def droby_dump
		MarshalledTask.new(to_s, drb_object, self.model, plan, arguments, data,
				   :mission => mission?, :started => started?, 
				   :finished => finished?, :success => success?)
	    end
	end
	class MarshalledTask < MarshalledPlanObject
	    attr_reader :arguments, :data, :flags
	    def initialize(remote_name, remote_object, model, plan, arguments, data, flags)
		super(remote_name, remote_object, model, plan)
		@arguments, @data, @flags = arguments, data, flags
	    end

	    def self._load(str)
		droby_load(str) do |data|
		    MarshalledTask.new(*data)
		end
	    end
	    def marshal_format; super << arguments.droby_dump << Distributed.format(data) << flags end

	    def update(peer, task)
		super
		return unless task.plan

		task.started  = flags[:started]
		task.finished = flags[:finished]
		task.success  = flags[:success]
		task.mission  = flags[:mission]

		Distributed.update([task]) do
		    task.arguments.merge(arguments)
		    task.data = data
		end
	    end
	end
    end
end

