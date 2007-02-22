require 'roby'
require 'roby/distributed/objects'

module Roby::Distributed
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
		raise NotOwner, "cannot add a relation between tasks we don't own.  #{self} by #{owners.to_a} and #{child} is owned by #{child.owners.to_a}"
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

    module TaskArgumentsOwnershipChecking
	def updating
	    if task.read_only?
		raise NotOwner, "cannot change the argument set of a task which is not owned"
	    end
	    super if defined? super
	end
    end
    Roby::TaskArguments.include TaskArgumentsOwnershipChecking

    module RemoteObjectProxy
	include RemoteObject
	# The object owners. This is always [remote_peer.remote_id].to_set
	attr_reader :owners
	# The marshalled object
	attr_reader :marshalled_object

	def initialize_remote_proxy(peer, marshalled_object)
	    unless marshalled_object.model.ancestors.find { |klass| klass == self.class.superclass }
		raise TypeError, "invalid remote task type. Was expecting #{self.class.superclass.name}, got #{marshalled_object.model.ancestors}"
	    end
	    @remote_object = marshalled_object.remote_object
	    @remote_peer = peer

	    @marshalled_object = marshalled_object
	    @owners = [peer.remote_id].to_set
	end

	def model
	    self.class.superclass
	end

	module ClassExtension
	    def name; "dProxy(#{super})" end
	end

	def droby_dump
	    marshalled_object.remote_object
	end
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
		self.command = true
	    end
	end
	def happened?; @happened || super end
	def command=(command)
	    if command 
		super(lambda {})
	    else
		super(nil)
	    end
	end
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
end

