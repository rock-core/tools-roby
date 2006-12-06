require 'roby/distributed/objects'
require 'roby/transactions/proxy'
class Roby::Plan
    def owners; @owners ||= [Roby::Distributed.state].to_set end
end
class Roby::PlanObject
    def owners; @owners ||= [Roby::Distributed.state].to_set end
    def read_only?; !Roby::Distributed.updating?([root_object]) && plan && !self.owners.subset?(plan.owners) end
end
class Roby::Transactions::Task
    def_delegator :@__getobj__, :owners
end
class Roby::Transactions::EventGenerator
    def_delegator :@__getobj__, :owners
end
class Roby::TaskEventGenerator
    def owners; task.owners end
end

module Roby::Distributed
    @updated_objects = ValueSet.new
    class << self
	attr_reader :updated_objects
	def updating?(objects)
	    updated_objects.include_all?(objects) 
	end
	def update(objects)
	    old_updated = updated_objects
	    @updated_objects |= objects

	    yield

	ensure
	    @updated_objects = old_updated
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
	# We can remove relation if one of the objects is owned by us
	def removing_child_object(child, type)
	    super if defined? super

	    if read_only? && child.read_only?
		raise NotOwner, "cannot remove a relation between two tasks we don't own"
	    end
	end
    end

    module TaskOwnershipChecking
	include OwnershipChecking
	# We can't add relations on objects we don't own
	def adding_child_object(child, type, info)
	    super if defined? super

	    if read_only? || child.read_only?
		raise NotOwner, "cannot add a relation between tasks we don't own"
	    end
	end
    end

    module EventOwnershipChecking
	include OwnershipChecking
	# We can add a relation if we own the child
	def adding_child_object(child, type, info)
	    super if defined? super
	    
	    if child.read_only?
		raise NotOwner, "cannot add an event relation on a child we don't own. #{child} is owned by #{child.owners.to_a} (#{plan.owners.to_a})"
	    end
	end
    end
    Roby::Task.include TaskOwnershipChecking
    Roby::EventGenerator.include EventOwnershipChecking

    module RemoteObjectProxy
	include RemoteObject
	# The object owners. This is always [peer_id].to_set
	attr_reader :owners
	# The marshalled object
	attr_reader :marshalled_object

	def initialize_remote_proxy(peer, marshalled_object)
	    unless marshalled_object.model.ancestors.find { |klass| klass == self.class.superclass }
		raise TypeError, "invalid remote task type. Was expecting #{self.class.superclass.name}, got #{marshalled_object.model.ancestors}"
	    end
	    @remote_object = marshalled_object.remote_object
	    @peer_id = peer.remote_id

	    @marshalled_object = marshalled_object
	    @owners = [peer.remote_id].to_set
	end

	module ClassExtension
	    def name; "dProxy(#{super})" end
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

