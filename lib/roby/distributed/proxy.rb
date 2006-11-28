module Roby::Distributed
    class RemoteTaskError < Exception
	attr_reader :task
	def initialize(remote_proxy)
	    @task = remote_proxy
	end
    end
    class InvalidRemoteOperation < RemoteTaskError; end

    @updated_objects = []
    class << self
	attr_reader :updated_objects
	def update(*objects)
	    objects.map! do |o|
		unless @updated_objects.include?(o)
		    @updated_objects << o
		end
	    end

	    yield

	ensure
	    objects.each { |o| @updated_objects.delete(o) if o }
	end
    end

    @@proxy_model = Hash.new

    # Builds a remote proxy model for +object_model+. +object_model+ is
    # either a string or a class. In the first case, it is interpreted
    # as a constant name.
    def self.RemoteProxy(object_model, peer, remote_object)
	if object_model.has_ancestor?(Roby::TaskEventGenerator)
	    peer.proxy(remote_object.task).event(remote_object.symbol)
	else
	    RemoteProxyModel(object_model).new(peer, remote_object)
	end
    end

    def self.RemoteProxyModel(object_model)
	object_model = constant(object_model) if object_model.respond_to?(:to_str)

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
	# The remote object we are proxying
	attr_reader :remote_object

	def initialize_remote_proxy(peer, remote_object)
	    unless remote_object.kind_of?(self.class.superclass)
		raise TypeError, "invalid remote task type. Was expecting #{self.class.name}, got #{remote_object.class}"
	    end

	    @remote_object = remote_object
	    @update	 = false
	    owners << peer
	end

	def update?; @update end
	def read_only?; !Roby::Distributed.updated_objects.include?(self) && !@update end
	def update
	    raise "recursive call to #update" if @update

	    @update = true
	    yield
	ensure
	    @update = false
	end

	# Forbid modification of relations
	def adding_child_object(child, type, info)
	    if read_only?
		raise InvalidRemoteOperation.new(self), "cannot change a remote object from outside a transaction"
	    end
	    super if defined? super
	end
	# Forbid modification of relations
	def removing_child_object(child, type)
	    if read_only? && !plan.owned?(child)
		raise InvalidRemoteOperation.new(self), "cannot change a remote object from outside a transaction"
	    end
	    super if defined? super
	end
	# Forbid modification of relations
	def adding_parent_object(parent, type, info)
	    if read_only?
		raise InvalidRemoteOperation.new(self), "cannot change a remote object from outside a transaction"
	    end
	    super if defined? super
	end
	# Forbid modification of relations
	def removing_parent_object(parent, type)
	    if read_only? && !plan.owned?(parent)
		raise InvalidRemoteOperation.new(self), "cannot change a remote object from outside a transaction"
	    end
	    super if defined? super
	end
    end

    module EventGeneratorProxy
	include RemoteObjectProxy
	def initialize(peer, remote_object)
	    initialize_remote_proxy(peer, remote_object)
	    @controlable = remote_object.controlable?
	    @history	 = remote_object.history

	    if @controlable
		super() do
		    raise NotImplementedError
		end
	    else
		super()
	    end
	end
	def controlable?; @controlable end
	def history; @history end

	def call(context)
	    raise NotImplementedError
	end
	def emit(context)
	    raise NotImplementedError
	end
    end

    #     include EventGeneratorProxy
    #     def initialize(peer, remote_object)
    #         super(peer, remote_object)
    #         @event_model   = remote_object.event_model
    #         @task	   = peer.proxy(remote_object.task)
    #     end
    # end

    module TaskProxy
	include RemoteObjectProxy
	def initialize(peer, remote_object)
	    initialize_remote_proxy(peer, remote_object)
	    super(remote_object.arguments)
	end
    end
end

