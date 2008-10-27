require 'roby'
require 'roby/distributed/protocol'
module Roby
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
	    "[ " << owners.map { |peer| peer.name }.join(", ") << " ]"
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
			raise "inconsistency for sibling on #{peer_sibling}: #{proxy} has #{current} while #{self} has #{remote_id}"
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
			plan.discover(proxy)
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
		      model.droby_dump(dest),  plan.droby_dump(dest), 
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

            # Create a new proxy which maps the object of +peer+ represented by
            # this communication intermediate.
	    def proxy(peer)
		local_object = peer.local_object(model).new
		if controlable
		    local_object.command = lambda { } 
		end
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
		unless task.has_event?(symbol)
		    Roby::Distributed.debug { "ignoring #{self}: #{symbol} is not known on #{task}" }
		    Roby::Distributed.ignore!
		end
		event = task.event(symbol)
		
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
		      model.droby_dump(dest),  plan.droby_dump(dest), 
		      Distributed.format(arguments, dest), Distributed.format(data, dest),
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
	    def proxy(peer)
		arguments = peer.local_object(self.arguments)
		peer.local_object(model).new(arguments) do
		    Roby::Distributed.updated_objects << self
		end

	    ensure
		Roby::Distributed.updated_objects.delete(self)
	    end

            # Updates an already existing proxy using the information contained
            # in this object.
	    def update(peer, task)
		super

		task.started  = flags[:started]
		task.finished = flags[:finished]
		task.success  = flags[:success]

		if task.mission? != flags[:mission]
		    plan = peer.local_object(self.plan) || peer.connection_space.plan
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

		task.arguments.merge!(peer.proxy(arguments))
		task.instance_variable_set("@data", peer.proxy(data))
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
	    def proxy(peer); peer.connection_space.plan end
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
	# Builds a remote proxy model for +object_model+. +object_model+ is
	# either a string or a class. In the first case, it is interpreted
	# as a constant name.
	def self.RemoteProxyModel(object_model)
	    object_model
	end

    end
end

