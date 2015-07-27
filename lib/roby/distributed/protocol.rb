require 'drb'
require 'set'
require 'utilrb/value_set'

class NilClass
    def droby_dump(dest); nil end
end
class Array
    def proxy(peer) # :nodoc:
	map do |element| 
	    catch(:ignore_this_call) { peer.local_object(element) }
	end
    end
end
class Hash
    def proxy(peer) # :nodoc:
	inject({}) do |h, (k, v)| 
	    h[peer.local_object(k)] = catch(:ignore_this_call) { peer.local_object(v) }
	    h
	end
    end
end
class Set
    def proxy(peer) # :nodoc:
	map do |element| 
	    catch(:ignore_this_call) { peer.local_object(element) }
	end.to_set
    end
end
class ValueSet
    def proxy(peer) # :nodoc:
	map do |element| 
	    catch(:ignore_this_call) { peer.local_object(element) }
	end.to_value_set
    end
end

class Module
    def droby_dump(dest)
	raise "can't dump modules"
    end
end
class Class
    def droby_dump(dest)
	raise "can't dump class #{self}"
    end
end

module Roby
    module Distributed
        # If set to true, enable some consistency-checking code in the
        # communication code.
	DEBUG_MARSHALLING = false

        # Dumps a constant by using its name. On reload, #proxy searches for a
        # constant with the same name, and raises ArgumentError if none exists.
        #
        # @example dump instances of a class that are registered as constants
        #   class Klass
        #     include DRobyConstant::Dump
        #   end
        #   # Obj can pass through droby
        #   Obj = Klass.new
        #
        # @example dump classes. You usually would prefer using {DRobyModel}
        #   # Klass can pass through droby
        #   class Klass
        #     extend DRobyConstant::Dump
        #   end
	class DRobyConstant
	    @@valid_constants = Hash.new
	    def self.valid_constants; @@valid_constants end
	    def to_s; "#<dRoby:Constant #{name}>" end

            # Generic implementation of the constant-dumping method. This is to
            # be included in all kind of classes which should be dumped by their
            # constant name (for intance RelationGraph).
	    module Dump
                # Returns a DRobyConstant object which references +self+. It
                # checks that +self+ can actually be referenced locally by
                # calling <tt>constant(name)</tt>, or raises ArgumentError if
                # it is not the case.
		def droby_dump(dest)
		    unless DRobyConstant.valid_constants[self]
                        begin
                            if name && (constant(name) == self)
                                return(DRobyConstant.valid_constants[self] = DRobyConstant.new(name))
                            end
                        rescue Exception => e
			end

                        Roby.info "could not resolve constant name for #{self}"
                        Roby.log_pp(e, Roby, :warn)
                        raise ArgumentError, "cannot resolve constant name for #{self}"
		    end
		    DRobyConstant.valid_constants[self]
		end
	    end

            # The constant name
	    attr_reader :name
	    def initialize(name); @name = name end
            # Returns the local object which can be referenced by this name, or
            # raises ArgumentError.
	    def proxy(peer); constant(name) end
	end

        class Roby::LocalizedError
            extend Roby::Distributed::DRobyConstant::Dump
        end
	class Roby::RelationGraph
	    include Roby::Distributed::DRobyConstant::Dump
	end

        # Dumps a model. When unmarshalling, it tries to search for the same
        # model in the constant hierarchy using its name. If it does not find
        # it, it rebuilds the same hierarchy using anonymous classes, basing
        # itself on the less abstract class known to both the remote and local
        # sides.
        #
        # If what you want to pass through droby is not a model class (i.e. if
        # the class hierarchy is not important), use {DRobyConstant} instead.
        #
        # @example
        #   class MyModel
        #     extend Roby::Distributed::DRobyModel
        #   end
        #
	class DRobyModel
	    @@remote_to_local = Hash.new
	    @@local_to_remote = Hash.new

	    # A name -> class map which maps remote models to local anonymous classes
	    # Remote models are always identified by their name
	    def self.remote_to_local; @@remote_to_local end
	    # A class => ID object which maps the anonymous classes we built for remote
	    # models to the remote ID of these remote models
	    def self.local_to_remote; @@local_to_remote end

            def name
                ancestors.first
            end

	    def to_s # :nodoc:
                "#<dRoby:Model #{ancestors.first.first}"
            end

            # Generic implementation of #droby_dump for all classes which
            # should be marshalled as DRobyModel.
            module Dump
                # Creates a DRobyModel object which can be used to reference
                # +self+ in the communication protocol. It properly takes into
                # account the anonymous models we have created to map remote
                # unknown models.
		def droby_dump(dest)
		    unless @__droby_marshalled__
			formatted = ancestors.map do |klass| 
			    if klass.instance_of?(Class) && !klass.is_singleton? && !klass.private_model?
				if result = DRobyModel.local_to_remote[klass]
				    result
				else
				    [klass.name, klass.remote_id]
				end
			    end
			end
			formatted.compact!
			@__droby_marshalled__ = DRobyModel.new(formatted)
		    end
		    @__droby_marshalled__
		end
	    end

            # The set of ancestors for the model, as a [name, remote_id] array
	    attr_reader :ancestors

            # Initialize a DRobyModel object with the given set of ancestors
	    def initialize(ancestors); @ancestors  = ancestors end
	    def _dump(lvl) # :nodoc:
                @__droby_marshalled__ ||= Marshal.dump(@ancestors) 
            end
	    def self._load(str) # :nodoc:
                DRobyModel.new(Marshal.load(str))
            end
            # Returns a local Class object which maps the given model. 
            #
            # See DRobyModel.local_model
	    def proxy(peer)
                factory = if peer then peer.method(:local_model)
                          else DRobyModel.method(:anon_model_factory)
                          end

	       	DRobyModel.local_model(ancestors.map { |name, id| [name, id.local_object] }, factory) 
	    end

            # True if the two objects reference the same model
	    def ==(other)
		other.kind_of?(DRobyModel) &&
		    ancestors == other.ancestors
	    end

            class << self
                attr_predicate :add_anonmodel_to_names?, true
            end
            @add_anonmodel_to_names = true

            def self.anon_model_factory(parent_model, name, add_anonmodel = DRobyModel.add_anonmodel_to_names?)
                Class.new(parent_model) do
                    singleton_class.class_eval do
                        define_method(:remote_name) { name }
                        if add_anonmodel
                            define_method(:name) { "AnonModel(#{remote_name})" }
                        else
                            define_method(:name) { remote_name }
                        end
                    end
                end
            end
	    
            # Returns a local representation of the given model. If the model
            # itself is known to us (i.e. there is a constant with the same
            # name), it is returned. Otherwise, the model hierarchy is
            # re-created using anonymous classes, branching the inheritance
            # chain at a point commonly known between the local plan manager
            # and the remote one.
	    def self.local_model(ancestors, unknown_model_factory = method(:anon_model_factory))
		name, id = ancestors.shift
		if !id.kind_of?(Distributed::RemoteID)
		    # this is a local task model
		    return id
                elsif model = @@remote_to_local[id]
		    return model
                end

		if name && !name.empty?
                    names = name.split('::')
                    # Look locally for the constant listed in the name
                    obj = Object
                    while subname = names.shift
                        if subname =~ /^[A-Z]\w*$/ && obj.const_defined_here?(subname)
                            obj = obj.const_get(subname)
                        else
                            obj = nil
                            break
                        end
                    end
                    if obj
                        @@remote_to_local[id] = obj
                        @@local_to_remote[model] = [name, id]
                        return obj
                    end
                end

		if !ancestors.empty?
		    parent_model = local_model(ancestors)
		    model = unknown_model_factory[parent_model, name]
		    @@remote_to_local[id] = model
		    @@local_to_remote[model] = [name, id]

		    model
		else
		    raise ArgumentError, "cannot find a root class"
		end
	    end
	end
	Roby::EventGenerator.extend Distributed::DRobyModel::Dump

        # Dumping intermediate for Task classes. This dumps both the ancestor
        # list via DRobyModel and the list of task tags.
	class DRobyTaskModel < DRobyModel
            # Set of task tags the task model was referring to
	    attr_reader :tags
            # Create a DRobyTaskModel with the given tags and ancestor list
	    def initialize(tags, ancestors)
		super(ancestors)
		@tags = tags
	    end

            # Generic implementation of #droby_dump for all classes which
            # should be marshalled as DRobyTaskModel.
	    module Dump
		include DRobyModel::Dump

                # This augments DRobyModel::Dump#droby_dump by taking into
                # account TaskService modules in the ancestors list.
		def droby_dump(dest)
		    unless @__droby_marshalled__
			formatted_class = super
			tags = ancestors.map do |mod|
			    if mod.kind_of?(Roby::Models::TaskServiceModel)
				mod.droby_dump(dest)
			    end
			end
			tags.compact!
			@__droby_marshalled__ = DRobyTaskModel.new(tags.reverse, formatted_class.ancestors)
		    end
		    @__droby_marshalled__
		end
	    end

            # True if +other+ describes the same task model than +self+
	    def ==(other)
		super &&
		    tags == other.tags
	    end

	    def _dump(lvl) # :nodoc:
                @__droby_marshalled__ ||= Marshal.dump([tags, ancestors])
            end
	    def self._load(str) # :nodoc:
                DRobyTaskModel.new(*Marshal.load(str)) 
            end

            # Returns or creates a Task-subclass which matches the task model
            # described by this object
	    def proxy(peer)
		model = super
		tags.each do |tag|
		    tag = tag.proxy(nil)
		    model.include tag unless model < tag
		end

		model
	    end
	end
	Roby::Task.extend Distributed::DRobyTaskModel::Dump
    end

    class BasicObject::DRoby
        # The set of remote siblings for that object, as known by the peer who
        # called #droby_dump. This is used to match object identity among plan
        # managers.
	attr_reader :remote_siblings
        # The set of owners for that object.
        attr_reader :owners
        # Create a BasicObject::DRoby object with the given information
	def initialize(remote_siblings, owners)
	    @remote_siblings, @owners = remote_siblings, owners
	end

	def remote_siblings_to_s # :nodoc:
	    "{ " << remote_siblings.map { |peer, id| id.to_s(peer) }.join(", ") << " }"
	end
	def owners_to_s # :nodoc:
	    BasicObject::DRoby.owners_to_s(self)
	end
        def self.owners_to_s(object)
	    "[ " << object.owners.map(&:name).join(", ") << " ]"
        end
	def to_s # :nodoc:
            "#<dRoby:BasicObject#{remote_siblings_to_s} owners=#{owners_to_s}>" 
        end

        # If we know of a sibling on +peer+, return it. Otherwise, raises RemotePeerMismatch.
	def sibling_on(peer)
	    remote_siblings.each do |m_peer, remote_id|
		if m_peer.peer_id == peer.remote_id
		    return remote_id
		end
	    end
	    raise RemotePeerMismatch, "#{self} has no known sibling on #{peer}"
	end

        # Update an existing proxy, using the information stored in this DRoby
        # object.
	def update(peer, proxy)
	    proxy.owners.clear
	    owners.each do |m_owner|
		proxy.owners << peer.local_object(m_owner)
	    end

	    remote_siblings.each do |m_peer_sibling, remote_id|
		peer_sibling = peer.local_object(m_peer_sibling)

		if current = proxy.remote_siblings[peer_sibling]
		    if current != remote_id && peer_sibling != Roby::Distributed
			raise Roby::Distributed::SiblingMismatch.new(proxy, peer_sibling, remote_id), "inconsistency for sibling on #{peer_sibling}: #{proxy} has #{current} while #{self} has #{remote_id}"
		    end
		else
		    proxy.sibling_of(remote_id, peer_sibling)
		end
	    end
	end
    end

    # Base class for all marshalled plan objects.
    class PlanObject::DRoby < BasicObject::DRoby
        # The model for this plan object
	attr_reader :model
        # The plan of this object
        attr_reader :plan

        # Create a DRoby object with the given information.  See also
        # BasicObject::DRoby
	def initialize(remote_siblings, owners, model, plan)
	    super(remote_siblings, owners)
	    @model, @plan = model, plan
	end

	def to_s # :nodoc:
            "#<dRoby:#{model.ancestors.first.first}#{remote_siblings_to_s} plan=#{plan} owners=#{owners_to_s}>" 
        end

        # Update an existing proxy, using the information stored in this DRoby
        # object.
	def update(peer, proxy)
	    super(peer, proxy)

	    if proxy.root_object?
		if self.plan
		    plan = peer.local_object(self.plan)
		    return if proxy.plan == plan
		    Distributed.update_all([plan, proxy]) do
			plan.add(proxy)
		    end
		end
	    end
	end
    end

    class EventGenerator
	def _dump(lvl) # :nodoc:
            Marshal.dump(remote_id) 
        end
	def self._load(str) # :nodoc:
            Marshal.load(str) 
        end

        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    DRoby.new(remote_siblings.droby_dump(dest), owners.droby_dump(dest),
		      Distributed.format(model, dest),  Distributed.format(plan, dest), 
		      controlable?, happened?)
	end

        # An intermediate representation of EventGenerator objects suitable to
        # be sent to our peers.
	class DRoby < PlanObject::DRoby
            # True if the generator is controlable
	    attr_reader :controlable
            # True if the generator has already been emitted once at the time
            # EventGenerator#droby_dump has been called.
            attr_reader :happened

            # Create a DRoby object with the given information.  See also
            # PlanObject::DRoby
	    def initialize(remote_siblings, owners, model, plan, controlable, happened)
		super(remote_siblings, owners, model, plan)
		@controlable, @happened = controlable, happened
	    end

            # Common code used for both EventGenerator::DRoby and
            # TaskEventGenerator::DRoby
            def self.setup_event_proxy(peer, local_object, marshalled)
		if marshalled.controlable
		    local_object.command = lambda { } 
		end
		local_object
            end

            # Create a new proxy which maps the object of +peer+ represented by
            # this communication intermediate.
	    def proxy(peer)
		local_object = peer.local_object(model).new
                DRoby.setup_event_proxy(peer, local_object, self)
                local_object
	    end

            # Updates an already existing proxy using the information contained
            # in this object.
	    def update(peer, proxy)
		super
		if happened && !proxy.happened?
		    proxy.instance_eval { @happened = true }
		end
	    end
	end
    end

    class Event
        class DRoby
            attr_reader :propagation_id
            attr_reader :time
            attr_reader :generator
            attr_reader :context

            def initialize(propagation_id, time, generator, context)
                @propagation_id, @time, @generator, @context = propagation_id, time, generator, context
            end

	    def proxy(peer)
                generator = peer.local_object(self.generator)

                context = peer.local_object(context)
                generator.new(context, propagation_id, time)
            end
        end

        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    DRoby.new(propagation_id, time, Distributed.format(generator, dest), Distributed.format(context, dest))
	end
    end

    class TaskEventGenerator
	def _dump(lvl) # :nodoc:
            Marshal.dump(remote_id) 
        end
	def self._load(str) # :nodoc:
            Marshal.load(str) 
        end
        
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    DRoby.new(controlable?, happened?, Distributed.format(task, dest), symbol)
	end

        # An intermediate representation of TaskEventGenerator objects suitable
        # to be sent to our peers.
	class DRoby
            # True if the generator is controlable
            attr_reader :controlable
            # True if the generator has already emitted once at the time
            # TaskEventGenerator#droby_dump has been called.
            attr_reader :happened
            # An object representing the task of this generator on our remote
            # peer.
            attr_reader :task
            # The event name
            attr_reader :symbol

            # Create a new DRoby object with the given information
	    def initialize(controlable, happened, task, symbol)
		@controlable = controlable
		@happened = happened
		@task   = task
		@symbol = symbol
	    end

	    def to_s # :nodoc:
		if task.respond_to?(:model)
		    "#<dRoby:#{task.model.ancestors.first.first}/#{symbol}#{task.remote_siblings_to_s} task_arguments=#{task.arguments} plan=#{task.plan} owners=#{task.owners_to_s}>"
		else
		    "#<dRoby:#{task}/#{symbol}>"
		end
	    end

            # Create a new proxy which maps the object of +peer+ represented by
            # this communication intermediate.
	    def proxy(peer)
		task = peer.local_object(self.task)
		if !task.has_event?(symbol)
                    if task.respond_to?(:create_remote_event)
                        task.create_remote_event(symbol, peer, self)
                    else
                        Roby::Distributed.debug { "ignoring #{self}: #{symbol} is not known on #{task}" }
                        Roby::Distributed.ignore!
                    end
		end

		event = task.event(symbol)
                if !event.controlable? && controlable
                    if task.event(symbol).controlable?
                        event = task.event(symbol)
                    elsif task.respond_to?(:override_remote_event)
                        task.override_remote_event(symbol, peer, self)
                        event = task.event(symbol)
                    else
                        Roby::Distributed.warn { "ignoring #{self}(local=#{task}): #{symbol} is contingent locally and controlable remotely" }
                        Roby::Distributed.ignore!
                    end
                end
		
		if happened && !event.happened?
		    event.instance_eval { @happened = true }
		end
		event
	    end
	end
    end

    class Task
	def _dump(lvl) # :nodoc:
            Marshal.dump(remote_id) 
        end
	def self._load(str) # :nodoc:
            Marshal.load(str) 
        end
        
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    DRoby.new(remote_siblings.droby_dump(dest), owners.droby_dump(dest),
		      Distributed.format(model, dest), Distributed.format(plan, dest), 
		      Distributed.format(meaningful_arguments, dest), Distributed.format(data, dest),
		      :mission => mission?, :started => started?, 
		      :finished => finished?, :success => success?)
	end

        # An intermediate representation of Task objects suitable
        # to be sent to our peers.
	class DRoby < PlanObject::DRoby
            # The set of dRoby-formatted arguments
	    attr_reader :arguments
            # The task's internal data
            attr_reader :data
            # A set of boolean flags which describe the task's status. It is a
            # symbol => bool flag where the following parameters are save:
            # started:: if the task has started
            # finished:: if the task has finished
            # success:: if the task has finished with success
            # mission:: if the task is a mission in its plan
            attr_reader :flags

            # Create a new DRoby object with the given information
            # See also PlanObject::DRoby.new
	    def initialize(remote_siblings, owners, model, plan, arguments, data, flags)
		super(remote_siblings, owners, model, plan)
		@arguments, @data, @flags = arguments, data, flags
	    end

	    def to_s # :nodoc:
		"#<dRoby:#{model.ancestors.first.first}#{remote_siblings_to_s} plan=#{plan} owners=#{owners_to_s} arguments=#{arguments}>"
	    end

            # Create a new proxy which maps the object of +peer+ represented by
            # this communication intermediate.
	    def proxy(object_manager)
		arguments = object_manager.local_object(self.arguments)
		object_manager.local_object(model).new(arguments)
	    end

            # Updates an already existing proxy using the information contained
            # in this object.
	    def update(object_manager, task)
		super

		task.started  = flags[:started]
		task.finished = flags[:finished]
		task.success  = flags[:success]

		if task.mission? != flags[:mission]
		    plan = object_manager.local_object(self.plan) || object_manager.plan
		    if plan.owns?(task)
			if flags[:mission]
			    plan.add_mission(task)
			else
			    plan.remove_mission(task)
			end
		    else
			task.mission = flags[:mission]
		    end
		end

		task.arguments.merge!(object_manager.local_object(arguments))
		task.instance_variable_set("@data", object_manager.local_object(data))
	    end
	end
    end

    class Plan
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    @__droby_marshalled__ ||= DRoby.new(Roby::Distributed.droby_dump(dest), remote_id)
	end

        # An intermediate representation of Plan objects suitable to be sent to
        # our peers.
        #
        # FIXME: It assumes that the only Plan object sent to the peers is
        # actually the main plan of the plan manager. We must fix that.
	class DRoby
            # The peer which manages this plan
	    attr_accessor :peer
            # The plan remote_id
            attr_accessor :id
            # Create a DRoby representation of a plan object with the given
            # parameters
	    def initialize(peer, id); @peer, @id = peer, id end
            # Create a new proxy which maps the object of +peer+ represented by
            # this communication intermediate.
	    def proxy(object_manager); object_manager.plan end
	    def to_s # :nodoc:
                "#<dRoby:Plan #{id.to_s(peer)}>" 
            end
            # The set of remote siblings for that object. This is used to avoid
            # creating proxies when not needed. See
            # PlanObject::DRoby#remote_siblings.
	    def remote_siblings; @remote_siblings ||= Hash[peer, id] end
            # If +peer+ is the plan's owner, returns #id. Otherwise, raises
            # RemotePeerMismatch. This is used to avoid creating proxies when not
            # needed. See BasicObject::DRoby#sibling_on.
	    def sibling_on(peer)
		if peer.remote_id == self.peer.peer_id then id
		else raise RemotePeerMismatch, "no known sibling for #{self} on #{peer}"
		end
	    end
	end
    end

    module Distributed
        # Exception thrown if a local transaction is being unmarshalled
        class LocalTransactionProxyError < NotImplementedError; end
    end

    class Transaction
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    @__droby_marshalled__ ||= DRoby.new(Roby::Distributed.droby_dump(dest), remote_id, Roby::Distributed.format(plan, dest))
	end

        # An intermediate representation of Transaction objects suitable to be
        # sent to our peers.
        #
        # Since it is meant for non-distributed transactions, it cannot be
        # unmarshalled into the local peer plan. It is only meant as a way to
        # convey information
	class DRoby < BasicObject::DRoby
            # The peer which manages this transaction
	    attr_accessor :peer
            # The transaction remote_id
            attr_accessor :id
            # The underlying plan
            attr_accessor :plan
            # Create a DRoby representation of a plan object with the given
            # parameters
	    def initialize(peer, id, plan)
                @peer, @id, @plan = peer, id, plan
                super({ peer => id }, [])
            end
            # Create a new proxy which maps the object of +peer+ represented by
            # this communication intermediate.
            #
            # The 
            def proxy(object_manager); raise Distributed::LocalTransactionProxyError, "non-distributed transactions cannot have a local proxy" end
	    def to_s # :nodoc:
                "#<dRoby:Transaction #{id.to_s(peer)}>" 
            end

            def update(peer, proxy)
                super
            end
	end
    end

    module Distributed
	# Builds a remote proxy model for +object_model+. +object_model+ is
	# either a string or a class. In the first case, it is interpreted
	# as a constant name.
	def self.RemoteProxyModel(object_model)
	    object_model
	end
    end
end

Exception.extend Roby::Distributed::DRobyModel::Dump
class Exception
    # An intermediate representation of Exception objects suitable to
    # be sent to our peers.
    class DRoby
	attr_reader :model, :message, :backtrace
	def initialize(model, message, backtrace); @model, @message, @backtrace = model, message, backtrace end

        # Returns a local representation of the exception object +self+
        # describes. If the real exception message is not available, it reuses
        # the more-specific exception class which is available.
	def proxy(peer)
	    error_model = model.proxy(peer)
	    error = error_model.exception(self.message)
            error.set_backtrace(backtrace)
            error

	rescue Exception
	    # try to get a less-specific error model which does allow a simple
	    # message. In the worst case, we will fall back to Exception itself
	    #
	    # However, include the real model name in the message
	    message = "#{self.message} (#{model.ancestors.first.first})"
	    for model in error_model.ancestors
		next unless model.kind_of?(Class)
		begin
		    error = model.exception(message)
                    error.set_backtrace(backtrace)
                    return error
		rescue ArgumentError
		end
	    end
	end
    end

    # Returns an intermediate representation of +self+ suitable to be sent to
    # the +dest+ peer.
    def droby_dump(dest); DRoby.new(self.class.droby_dump(dest), message, backtrace) end
end

