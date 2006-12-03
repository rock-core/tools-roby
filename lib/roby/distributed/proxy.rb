require 'roby/distributed/objects'
require 'roby/transactions/proxy'
class Roby::Plan
    def owners; @owners ||= [Roby::Distributed.state].to_value_set end
end
class Roby::PlanObject
    def owners; @owners ||= [Roby::Distributed.state].to_value_set end
end
class Roby::Transactions::Task
    def_delegator :@__getobj__, :owners
end
class Roby::Transactions::EventGenerator
    def_delegator :@__getobj__, :owners
end

module Roby::Distributed
    class RemoteTaskError < Exception
	attr_reader :task
	def initialize(remote_proxy)
	    @task = remote_proxy
	end
    end
    class InvalidRemoteTaskOperation < RemoteTaskError; end

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

    module OwnershipChecking
	def read_only?; plan && !plan.owners.include_all?(self.owners) end

	# Forbid modification of relations
	def adding_child_object(child, type, info)
	    if read_only?
		raise InvalidRemoteTaskOperation.new(self), "cannot change a remote object from outside a transaction"
	    end
	    super if defined? super
	end
	# Forbid modification of relations
	def removing_child_object(child, type)
	    if read_only? && !plan.owners.include_all?(child.owners)
		raise InvalidRemoteTaskOperation.new(self), "cannot change a remote object from outside a transaction"
	    end
	    super if defined? super
	end
	# Forbid modification of relations
	def adding_parent_object(parent, type, info)
	    if read_only?
		raise InvalidRemoteTaskOperation.new(self), "cannot change a remote object from outside a transaction"
	    end
	    super if defined? super
	end
	# Forbid modification of relations
	def removing_parent_object(parent, type)
	    if read_only? && !plan.owners.include_all?(parent.owners)
		raise InvalidRemoteTaskOperation.new(self), "cannot change a remote object from outside a transaction"
	    end
	    super if defined? super
	end
    end
    Roby::PlanObject.include OwnershipChecking

    module RemoteObjectProxy
	include RemoteObject
	# The remote object we are proxying
	attr_reader :owners
	# The marshalled object
	attr_reader :marshalled_object

	def initialize_remote_proxy(peer, marshalled_object)
	    unless marshalled_object.ancestors.find { |klass| klass == self.class.superclass }
		raise TypeError, "invalid remote task type. Was expecting #{self.class.superclass.name}, got #{marshalled_object.ancestors}"
	    end
	    @remote_object = marshalled_object.remote_object
	    @peer_id = peer.remote_id

	    @marshalled_object = marshalled_object
	    @update = false
	    @owners = [peer.remote_id].to_value_set
	end

	module ClassExtension
	    def name; "dProxy(#{super})" end
	end

	def update?; @update end
	def read_only?; !(Roby::Distributed.updated_objects.include?(self) || @update) && super end
	def update
	    raise "recursive call to #update" if @update

	    @update = true
	    yield
	ensure
	    @update = false
	end


	def droby_dump
	    marshalled_object.dup
	end
    end

    module EventGeneratorProxy
	include RemoteObjectProxy
	def initialize_remote_proxy(peer, marshalled_object)
	    initialize_remote_proxy(peer, marshalled_object)
	    @controlable = marshalled_object.controlable
	    @history	 = marshalled_object.history

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

    module TaskProxy
	include RemoteObjectProxy
	def initialize(peer, marshalled_object)
	    initialize_remote_proxy(peer, marshalled_object)
	    super(marshalled_object.arguments)
	end
    end
end

