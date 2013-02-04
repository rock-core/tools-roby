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
    class TaskModelTag
	@@local_to_remote = Hash.new
	@@remote_to_local = Hash.new
	def self.local_to_remote; @@local_to_remote end
	def self.remote_to_local; @@remote_to_local end

	class DRoby
	    attr_reader :tagdef
	    def initialize(tagdef); @tagdef = tagdef end
	    def _dump(lvl); @__droby_marshalled__ ||= Marshal.dump(tagdef) end
	    def self._load(str); DRoby.new(Marshal.load(str)) end

	    def proxy(peer)
		including = []
                factory = if peer then peer.method(:local_task_tag)
                          else
                              DRoby.method(:anon_tag_factory)
                          end

		tagdef.each do |name, remote_tag|
		    tag = DRoby.local_tag(name, remote_tag, factory) do |tag|
			including.each { |mod| tag.include mod }
		    end
		    including << tag
		end
		including.last
	    end

            def self.anon_tag_factory(tag_name)
                Roby::TaskModelTag.new do
                    define_method(:name) { tag_name }
                end
            end

	    def self.local_tag(name, remote_tag, unknown_model_factory = method(:anon_tag_factory))
		if !remote_tag.kind_of?(Distributed::RemoteID)
		    remote_tag
		elsif local_model = TaskModelTag.remote_to_local[remote_tag]
		    local_model
		else
		    if name && !name.empty?
			local_model = constant(name) rescue nil
		    end
		    unless local_model
			local_model = unknown_model_factory[name]
			TaskModelTag.remote_to_local[remote_tag] = local_model
			TaskModelTag.local_to_remote[local_model] = [name, remote_tag]
			yield(local_model) if block_given?
		    end
		    local_model
		end
	    end

	    def ==(other)
		other.kind_of?(DRoby) && 
		    tagdef.zip(other.tagdef).all? { |a, b| a == b }
	    end
	end

	def droby_dump(dest)
	    unless @__droby_marshalled__
		tagdef = ancestors.map do |mod|
		    if mod.kind_of?(Roby::TaskModelTag)
			unless id = TaskModelTag.local_to_remote[mod]
			    id = [mod.name, mod.remote_id]
			end
			id
		    end
		end
		tagdef.compact!
		@__droby_marshalled__ = DRoby.new(tagdef.reverse)
	    end
	    @__droby_marshalled__
	end
    end

    class TaskMatcher
        # An intermediate representation of TaskMatcher objects suitable to be
        # sent to our peers.
	class DRoby
	    attr_reader :args
	    def initialize(args); @args = args end
	    def _dump(lvl) # :nodoc:
                Marshal.dump(args) 
            end

	    def self._load(str) # :nodoc:
		setup_matcher(TaskMatcher.new, Marshal.load(str))
	    end

            # Common initialization of a TaskMatcher object from the given
            # argument set. This is to be used by DRoby-dumped versions of
            # subclasses of TaskMatcher.
	    def self.setup_matcher(matcher, args)
		model, args, predicates, neg_predicates, owners = *args
		model  = model.proxy(nil) if model
		owners = owners.map { |peer| peer.local_object(nil) } if owners
		args   = args

		matcher = matcher.with_model(model).with_arguments(args || {})
		matcher.predicates.merge(predicates)
		matcher.owners.concat(owners)
		matcher
	    end
	end

        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer. +klass+ is the actual class of the intermediate
        # representation. It is used for code reuse by subclasses of
        # TaskMatcher.
	def droby_dump(dest, klass = DRoby)
	    args = [model, arguments, predicates, neg_predicates, owners]
	    klass.new args.droby_dump(dest)
	end
    end
    class Query
        # An intermediate representation of Query objects suitable to be sent
        # to our peers.
	class DRoby # :nodoc:
	    attr_reader :plan_predicates, :neg_plan_predicates, :matcher
	    def initialize(plan_predicates, neg_plan_predicates, matcher)
		@plan_predicates, @neg_plan_predicates, @matcher = 
		    plan_predicates, neg_plan_predicates, matcher
	    end

	    def _dump(lvl) # :nodoc:
		Marshal.dump([plan_predicates, neg_plan_predicates, matcher])
	    end

	    def self._load(str) # :nodoc:
		DRoby.new(*Marshal.load(str))
	    end

	    def to_query(plan)
		query = TaskMatcher::DRoby.setup_matcher(plan.find_tasks, matcher)
		query.plan_predicates.concat(plan_predicates)
		query.neg_plan_predicates.concat(neg_plan_predicates)
		query
	    end

	    def proxy(peer)
		to_query(peer.connection_space.plan)
	    end
	end
	
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    marshalled_matcher = super
	    DRoby.new(plan_predicates, neg_plan_predicates, marshalled_matcher.args)
	end
    end

    class OrTaskMatcher
        # An intermediate representation of OrTaskMatcher objects suitable to
        # be sent to our peers.
	class DRoby < TaskMatcher::DRoby
	    def self._load(str) # :nodoc:
		args = Marshal.load(str)
		ops  = args.pop
		setup_matcher(OrTaskMatcher.new(*ops), args)
	    end
	end
	
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    m = super(dest, OrTaskMatcher::DRoby)
	    m.args << @ops
	    m
	end
    end
    class AndTaskMatcher
        # An intermediate representation of AndTaskMatcher objects suitable to
        # be sent to our peers.
	class DRoby < TaskMatcher::DRoby
	    def self._load(str) # :nodoc:
		args = Marshal.load(str)
		ops  = args.pop
		setup_matcher(AndTaskMatcher.new(*ops), args)
	    end
	end
	
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    m = super(dest, AndTaskMatcher::DRoby)
	    m.args << @ops
	    m
	end
    end
    class NegateTaskMatcher
        # An intermediate representation of NegateTaskMatcher objects suitable to
        # be sent to our peers.
	class DRoby < TaskMatcher::DRoby
	    def self._load(str) # :nodoc:
		args = Marshal.load(str)
		op  = args.pop
		setup_matcher(NegateTaskMatcher.new(op), args)
	    end
	end
	
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
	    m = super(dest, NegateTaskMatcher::DRoby)
	    m.args << @op
	    m
	end
    end
end

module Roby
    module Distributed
        # If set to true, enable some consistency-checking code in the
        # communication code.
	DEBUG_MARSHALLING = false

	class Peer
            # An intermediate representation of Peer objects suitable to be
            # sent to our peers.
	    class DRoby # :nodoc:
		attr_reader :name, :peer_id
		def initialize(name, peer_id); @name, @peer_id = name, peer_id end
		def hash; peer_id.hash end
		def eql?(obj); obj.respond_to?(:peer_id) && peer_id == obj.peer_id end
		alias :== :eql?

		def to_s; "#<dRoby:Peer #{name} #{peer_id}>" end 
		def proxy(peer)
		    if peer = Distributed.peer(peer_id)
			peer
		    else
			raise "unknown peer ID #{peer_id}, known peers are #{Distributed.peers}"
		    end
		end
	    end
	
            # Returns an intermediate representation of +self+ suitable to be sent
            # to the +dest+ peer.
	    def droby_dump(dest = nil)
		@__droby_marshalled__ ||= DRoby.new(remote_name, remote_id)
	    end
	end

        # Dumps a constant by using its name. On reload, #proxy searches for a
        # constant with the same name, and raises ArgumentError if none exists.
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

	class Roby::RelationGraph
	    include Roby::Distributed::DRobyConstant::Dump
	end

	# Dumps a model (an event, task or planner class). When unmarshalling,
	# it tries to search for the same model. If it does not find it, it
	# rebuilds the same hierarchy using anonymous classes, basing itself on
	# the less abstract class known to both the remote and local sides.
	class DRobyModel
	    @@remote_to_local = Hash.new
	    @@local_to_remote = Hash.new

	    # A name -> class map which maps remote models to local anonymous classes
	    # Remote models are always identified by their name
	    def self.remote_to_local; @@remote_to_local end
	    # A class => ID object which maps the anonymous classes we built for remote
	    # models to the remote ID of these remote models
	    def self.local_to_remote; @@local_to_remote end
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

            def self.anon_model_factory(parent_model, name, add_anonmodel = true)
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
                        if obj.const_defined_here?(subname)
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
                # account TaskModelTag modules in the ancestors list.
		def droby_dump(dest)
		    unless @__droby_marshalled__
			formatted_class = super
			tags = ancestors.map do |mod|
			    if mod.instance_of?(Roby::TaskModelTag)
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
end

Exception.extend Roby::Distributed::DRobyModel::Dump
class Exception
    # An intermediate representation of Exception objects suitable to
    # be sent to our peers.
    class DRoby
	attr_reader :model, :message
	def initialize(model, message); @model, @message = model, message end

        # Returns a local representation of the exception object +self+
        # describes. If the real exception message is not available, it reuses
        # the more-specific exception class which is available.
	def proxy(peer)
	    error_model = model.proxy(peer)
	    error_model.exception(self.message)

	rescue Exception
	    # try to get a less-specific error model which does allow a simple
	    # message. In the worst case, we will fall back to Exception itself
	    #
	    # However, include the real model name in the message
	    message = "#{self.message} (#{model.ancestors.first.first})"
	    for model in error_model.ancestors
		next unless model.kind_of?(Class)
		begin
		    return model.exception(message)
		rescue ArgumentError
		end
	    end
	end
    end

    # Returns an intermediate representation of +self+ suitable to be sent to
    # the +dest+ peer.
    def droby_dump(dest); DRoby.new(self.class.droby_dump(dest), message) end
end

module Roby
    class LocalizedError
        class DRoby
            attr_reader :model, :failure_point, :message
            def initialize(model, failure_point, message); @model, @failure_point, @message = model, failure_point, message end

            def proxy(peer)
                failure_point = peer.local_object(self.failure_point)
                error = LocalizedError.new(failure_point)
                error.exception(message)
                error
            end
        end

        # Returns an intermediate representation of +self+ suitable to be sent to
        # the +dest+ peer.
        def droby_dump(dest); DRoby.new(self.class.droby_dump(dest), Distributed.format(failure_point, dest), message) end
    end
end

