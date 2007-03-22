require 'roby'
require 'roby/distributed/protocol'
module Roby
    class BasicObject::DRoby
	attr_reader :remote_siblings, :owners
	def initialize(remote_siblings, owners)
	    @remote_siblings, @owners = remote_siblings, owners
	end

	def remote_siblings_to_s
	    "{ " << remote_siblings.map { |peer, id| id.to_s(peer) }.join(", ") << " }"
	end
	def owners_to_s
	    "[ " << owners.map { |peer| peer.name }.join(", ") << " ]"
	end
	def to_s; "#<dRoby:BasicObject#{remote_siblings_to_s} owners=#{owners_to_s}>" end
	def sibling_on(peer)
	    remote_siblings.each do |m_peer, remote_id|
		if m_peer.peer_id == peer.remote_id
		    return remote_id
		end
	    end
	    raise RemotePeerMismatch, "#{self} has no known sibling on #{peer}"
	end

	def update(peer, proxy)
	    proxy.owners.clear
	    owners.each do |m_owner|
		proxy.owners << peer.local_object(m_owner)
	    end

	    peer.local_object(remote_siblings).each do |peer_sibling, remote_id|
		next if peer_sibling == Roby::Distributed
		if current = proxy.remote_siblings[peer_sibling]
		    if current != remote_id
			raise "inconsistency"
		    end
		else
		    proxy.sibling_of(remote_id, peer_sibling)
		end
	    end
		
	    proxy.remote_siblings.merge! peer.local_object(remote_siblings)

	end
    end

    # Base class for all marshalled plan objects.
    class PlanObject::DRoby < BasicObject::DRoby
	attr_reader :model, :plan
	def initialize(remote_siblings, owners, model, plan)
	    super(remote_siblings, owners)
	    @model, @plan = model, plan
	end

	def to_s; "#<dRoby:#{model.ancestors.first.first}#{remote_siblings_to_s} plan=#{plan} owners=#{owners_to_s}>" end

	# Updates the status of the local object if needed
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
	def _dump(lvl); Marshal.dump(remote_id) end
	def self._load(str); Marshal.load(str) end
	def droby_dump(dest)
	    DRoby.new(remote_siblings.droby_dump(dest), owners.droby_dump(dest),
		      model.droby_dump(dest),  plan.droby_dump(dest), 
		      controlable?, happened?)
	end

	class DRoby < PlanObject::DRoby
	    attr_reader :controlable, :happened
	    def initialize(remote_siblings, owners, model, plan, controlable, happened)
		super(remote_siblings, owners, model, plan)
		@controlable, @happened = controlable, happened
	    end

	    def proxy(peer)
		peer.local_object(model).new(controlable)
	    end

	    def update(peer, proxy)
		super
		if happened && !proxy.happened?
		    proxy.instance_eval { @happened = true }
		end
	    end
	end
    end

    class TaskEventGenerator
	def _dump(lvl); Marshal.dump(remote_id) end
	def self._load(str); Marshal.load(str) end
	def droby_dump(dest)
	    DRoby.new(happened?, task.droby_dump(dest), symbol)
	end

	class DRoby
	    attr_reader :happened, :task, :symbol
	    def initialize(happened, task, symbol)
		@happened = happened
		@task   = task
		@symbol = symbol
	    end

	    def to_s
		"#<dRoby:#{task.model.ancestors.first.first}/#{symbol}#{task.remote_siblings_to_s} task_arguments=#{task.arguments} plan=#{task.plan} owners=#{task.owners_to_s}>"
	    end


	    def proxy(peer)
		task = peer.local_object(self.task)
		return unless task.has_event?(symbol)
		event = task.event(symbol)
		
		if happened && !event.happened?
		    event.instance_eval { @happened = true }
		end
		event
	    end
	end
    end

    class Task
	def _dump(lvl); Marshal.dump(remote_id) end
	def self._load(str); Marshal.load(str) end
	def droby_dump(dest)
	    DRoby.new(remote_siblings.droby_dump(dest), owners.droby_dump(dest),
		      model.droby_dump(dest),  plan.droby_dump(dest), 
		      Distributed.format(arguments, dest), Distributed.format(data, dest),
		      :mission => mission?, :started => started?, 
		      :finished => finished?, :success => success?)
	end

	class DRoby < PlanObject::DRoby
	    attr_reader :arguments, :data, :flags
	    def initialize(remote_siblings, owners, model, plan, arguments, data, flags)
		super(remote_siblings, owners, model, plan)
		@arguments, @data, @flags = arguments, data, flags
	    end

	    def to_s
		"#<dRoby:#{model.ancestors.first.first}#{remote_siblings_to_s} plan=#{plan} owners=#{owners_to_s} arguments=#{arguments}>"
	    end

	    def proxy(peer)
		arguments = peer.local_object(self.arguments)
		peer.local_object(model).new(arguments) do
		    Roby::Distributed.updated_objects << self
		end

	    ensure
		Roby::Distributed.updated_objects.delete(self)
	    end

	    def update(peer, task)
		super

		task.started  = flags[:started]
		task.finished = flags[:finished]
		task.success  = flags[:success]
		task.mission  = flags[:mission]
		task.arguments.merge!(peer.proxy(arguments))
		task.instance_variable_set("@data", peer.proxy(data))
	    end
	end
    end

    class Plan
	class DRoby
	    attr_accessor :peer, :id
	    def initialize(peer, id); @peer, @id = peer, id end
	    def proxy(peer); peer.connection_space.plan end
	    def to_s; "#<dRoby:Plan #{id.to_s(peer)}>" end
	    def remote_siblings; Hash[peer, id] end
	    def sibling_on(peer)
		if peer.remote_id == self.peer.peer_id then id
		else raise ArgumentError, "no known sibling for #{self} on #{peer}"
		end
	    end
	end
	def droby_dump(dest)
	    @__droby_marshalled__ ||= DRoby.new(Roby::Distributed.droby_dump(dest), Roby.plan.remote_id)
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

