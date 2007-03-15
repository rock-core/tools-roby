require 'drb'
require 'rinda/tuplespace'
require 'utilrb/value_set'
require 'roby/droby'

require 'roby'

class DRbObject
    alias __drbobject_dump__ _dump
    def _dump(lvl)
	@__droby_marshalled__ ||= __drbobject_dump__(lvl)
    end
end

class NilClass
    def droby_dump(dest); nil end
end
class Array
    def proxy(peer) # :nodoc:
	map { |element| peer.proxy(element) }
    end
end
class Hash
    def proxy(peer) # :nodoc:
	inject({}) { |h, (k, v)| h[k] = peer.proxy(v); h }
    end
end
class Set
    def proxy(peer) # :nodoc:
	map(&peer.method(:proxy)).to_set 
    end
end
class ValueSet
    def proxy(peer) # :nodoc:
	map(&peer.method(:proxy)).to_value_set 
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

class Exception
    class DRoby
	attr_reader :error
	def initialize(error); @error = error end
	def self._load(str); Marshal.load(str) end
	def _dump(lvl = -1)
	    Marshal.dump(error)
	rescue TypeError
	    Marshal.dump(DRb::DRbRemoteError.new(error))
	end
    end

    def droby_dump(dest); DRoby.new(self) end
end

module Roby
    class << Task
	def droby_dump(dest); Roby::Distributed::DRobyTaskModel.new(ancestors) end
    end
    class << EventGenerator
	def droby_dump(dest); Roby::Distributed::DRobyModel.new(ancestors) end
    end
    class << Planning::Planner
	def droby_dump(dest); Roby::Distributed::DRobyModel.new(ancestors) end
    end
    class TaskModelTag
	class DRoby
	    @@local_to_remote = Hash.new
	    @@remote_to_local = Hash.new
	    @@marshalled_tags = Hash.new

	    attr_reader :name, :tag
	    def initialize(tag); @tag = tag end
	    def _dump(lvl)
		unless marshalled = @@marshalled_tags[tag]
		    tagdef = tag.ancestors.map do |mod|
			if mod.instance_of?(Roby::TaskModelTag)
			    unless id = @@local_to_remote[mod]
				id = [mod.name, DRbObject.new(mod)]
			    end
			    id
			end
		    end
		    tagdef.compact!
		    marshalled = Marshal.dump(tagdef)
		    @@marshalled_tags[tag] = marshalled
		end
		marshalled
	    end

	    def self._load(str)
		tagdef    = Marshal.load(str).reverse
		including = []
		tagdef.each do |name, remote_tag|
		    tag = local_tag(name, remote_tag) do |tag|
			including.each { |mod| tag.include mod }
		    end
		    including << tag
		end
		including.last
	    end

	    def self.local_tag(name, remote_tag)
		if !remote_tag.kind_of?(DRbObject)
		    remote_tag
		elsif local_model = @@remote_to_local[remote_tag]
		    local_model
		else
		    if name && !name.empty?
			local_model = constant(name) rescue nil
		    end
		    unless local_model
			local_model = Roby::TaskModelTag.new do
			    define_method(:name) { name }
			end
			@@remote_to_local[remote_tag] = local_model
			@@local_to_remote[local_model] = [name, remote_tag]
			yield(local_model) if block_given?
		    end
		    local_model
		end
	    end
	end

	def droby_dump(dest); @__droby_marshalled__ ||= DRoby.new(self) end
    end

    class RelationGraph
	def droby_dump(dest); @__droby_marshalled__ ||= Distributed::DRobyConstant.new(self) end
    end

    class Plan
	class DRoby
	    attr_reader :remote_object
	    def initialize(remote_object); @remote_object = remote_object end
	    def proxy(peer)
		peer.connection_space.plan 
	    end

	    def to_s; "mPlan(#{remote_object})" end
	end
	def droby_dump(dest); @__droby_marshalled__ ||= DRoby.new(drb_object) end
    end

    class TaskMatcher
	class DRoby
	    attr_reader :args
	    def initialize(args); @args = args end
	    def _dump(lvl); Marshal.dump(args) end

	    def self._load(str)
		setup_matcher(TaskMatcher.new, Marshal.load(str))
	    end
	    def self.setup_matcher(matcher, args)
		model, args, improves, needs, predicates, neg_predicates, owners = *args

		matcher = matcher.with_model(model).with_arguments(args || {}).
		    which_improves(*improves).which_needs(*needs)
		matcher.predicates.merge(predicates)
		matcher.owners.concat(owners)
		matcher
	    end
	end
	def droby_dump(dest, klass = DRoby)
	    args = [model, arguments, improved_information, needed_information, predicates, neg_predicates, owners]
	    klass.new args.droby_dump(dest)
	end
    end
    class Query
	class DRoby
	    attr_reader :plan_predicates, :neg_plan_predicates, :matcher
	    def initialize(plan_predicates, neg_plan_predicates, matcher)
		@plan_predicates, @neg_plan_predicates, @matcher = 
		    plan_predicates, neg_plan_predicates, matcher
	    end

	    def _dump(lvl)
		Marshal.dump([plan_predicates, neg_plan_predicates, matcher])
	    end

	    def self._load(str)
		DRoby.new(*Marshal.load(str))
	    end
	    def proxy(peer)
		query = TaskMatcher::DRoby.setup_matcher(peer.connection_space.plan.find_tasks, matcher)
		query.plan_predicates.concat(plan_predicates)
		query.neg_plan_predicates.concat(neg_plan_predicates)
		query
	    end
	end
	
	def droby_dump(dest)
	    marshalled_matcher = super
	    DRoby.new(plan_predicates, neg_plan_predicates, marshalled_matcher.args)
	end
    end

    class OrTaskMatcher
	class DRoby < TaskMatcher::DRoby
	    def self._load(str)
		args = Marshal.load(str)
		ops  = args.pop
		setup_matcher(OrTaskMatcher.new(*ops), args)
	    end
	end
	def droby_dump(dest)
	    m = super(dest, OrTaskMatcher::DRoby)
	    m.args << @ops
	    m
	end
    end
    class AndTaskMatcher
	class DRoby < TaskMatcher::DRoby
	    def self._load(str)
		args = Marshal.load(str)
		ops  = args.pop
		setup_matcher(AndTaskMatcher.new(*ops), args)
	    end
	end
	def droby_dump(dest)
	    m = super(dest, AndTaskMatcher::DRoby)
	    m.args << @ops
	    m
	end
    end
    class NegateTaskMatcher
	class DRoby < TaskMatcher::DRoby
	    def self._load(str)
		args = Marshal.load(str)
		op  = args.pop
		setup_matcher(NegateTaskMatcher.new(op), args)
	    end
	end
	def droby_dump(dest)
	    m = super(dest, NegateTaskMatcher::DRoby)
	    m.args << @op
	    m
	end
    end
end

module Roby
    module Distributed
	class Peer
	    class DRoby
		attr_reader :peer_id
		def initialize(peer_id); @peer_id = peer_id end
		def _dump(lvl = -1)
		    @__droby_marshalled__ ||= Marshal.dump(peer_id)
		end
		def self._load(str)
		    peer_id = Marshal.load(str)
		    Distributed.peer(peer_id) rescue nil
		end
	    end

	    def droby_dump(dest)
		@__droby_marshalled__ ||= DRoby.new(remote_id)
	    end
	end

	def self.droby_dump(dest)
	    if Distributed.state 
		Distributed.state.droby_dump(dest)
	    end
	end

	# Dumps a constant by using its name
	class DRobyConstant
	    @@valid_constants = Hash.new

	    def initialize(obj)
		@obj = obj
		unless @@valid_constants[obj]
		    if const_obj = (constant(obj.name) rescue nil)
			@@valid_constants[obj] = Marshal.dump(@obj.name)
		    else
			raise ArgumentError, "invalid constant name #{obj.name}"
		    end
		end
	    end
	    def _dump(lvl = -1); @@valid_constants[@obj] end
	    def self._load(str)
		constant(Marshal.load(str))
	    end
	end

	# Dumps a model (an event, task or planner class). When unmarshalling,
	# it tries to search for the same model. If it does not find it, it
	# rebuilds the same hierarchy using anonymous classes, basing itself on
	# the less abstract class known to both the remote and local sides.
	class DRobyModel
	    # A name -> class map which maps remote models to local anonymous classes
	    # Remote models are always identified by their name
	    @@remote_to_local = Hash.new
	    # A class => ID object which maps the anonymous classes we built for remote
	    # models to the remote ID of these remote models
	    @@local_to_remote = Hash.new

	    attr_reader :ancestors
	    @@marshalled_models = Hash.new
	    def initialize(ancestors)
		@ancestors  = ancestors 
	    end
	    def _dump(lvl)
		base_model = ancestors.first
		unless marshalled = @@marshalled_models[base_model]
		    marshalled = ancestors.map do |klass| 
			if klass.instance_of?(Class) && !klass.is_singleton? 
			    if result = @@local_to_remote[klass]
				result
			    else
				[klass.name, DRbObject.new(klass)]
			    end
			end
		    end
		    marshalled.compact!
		    @@marshalled_models[base_model] = marshalled = Marshal.dump(marshalled)
		end
		marshalled
	    end
	    def self._load(str)
		ancestors = Marshal.load(str)
		DRobyModel.local_model(ancestors)
	    end
	    
	    def self.local_model(ancestors)
		name, id = ancestors.shift
		if !id.kind_of?(DRbObject)
		    # this is a local task model
		    id
		elsif !name.empty? && model = (constant(name) rescue nil)
		    model
		elsif model = @@remote_to_local[id]
		    model
		elsif !ancestors.empty?
		    parent_model = local_model(ancestors)
		    model = Class.new(parent_model) do
			singleton_class.class_eval do
			    define_method(:remote_name) { name }
			    define_method(:name) { "AnonModel(#{remote_name})" }
			end
		    end
		    @@remote_to_local[id] = model
		    @@local_to_remote[model] = [name, id]

		    model
		else
		    raise ArgumentError, "cannot find a root class"
		end
	    end
	end

	# Dumping intermediate for Task classes. This dumps both the ancestor list via
	# DRobyModel and the list of task tags.
	class DRobyTaskModel < DRobyModel
	    @@marshalled_task_models = Hash.new
	    def _dump(lvl)
		base_model = ancestors.first
		unless marshalled = @@marshalled_task_models[base_model]
		    marshalled_class = super
		    tags = ancestors.map do |mod|
			if mod.instance_of?(Roby::TaskModelTag)
			    mod.droby_dump(nil)
			end
		    end
		    tags.compact!
		    marshalled = Marshal.dump([tags, marshalled_class])
		    @@marshalled_task_models[base_model] = marshalled
		end
		marshalled
	    end
	    def self._load(str)
		tags, model = Marshal.load(str)
		model = super(model)
		tags.each do |tag|
		    model.include tag unless model < tag
		end

		model
	    end
	end

	# Returns true if it is marshallable in DRoby
	def self.marshallable?(object)
	    if object.respond_to?(:droby_dump)
		true
	    elsif object.kind_of?(DRbUndumped)
		false
	    else
		!!Marshal.dump(object) rescue nil
	    end
	end

	# Dumps +object+ in the dRoby protocol
	def self.dump(object, error = false)
	    if error
		Marshal.dump(DRb::DRbRemoteError.new(object))
	    else
		Marshal.dump(format(object))
	    end

	rescue Exception
	    case $!.message
	    when /while dumping/
		raise $!, "#{$!.message}\n  #{object}", $!.backtrace
	    else
		raise $!, "#{$!.message} while dumping\n  #{object}", $!.backtrace
	    end
	end

	class DRbMessage < DRb::DRbMessage
	    def dump(obj, error = false)
		str = Roby::Distributed.dump(obj, error)
		[str.size].pack('N') << str
	    end

	    def recv_request(stream)
		@current_method = super
	    end

	    def send_reply(stream, succ, result)  # :nodoc:
		str = begin
			  dumped_succ = dump(succ)
			  dumped_rslt = dump(result, !succ)
			  dumped_succ + dumped_rslt
		      rescue
			  backtrace = $!.backtrace
			  new_exception = $!.exception($!.message + " returning from #{@current_method[0]}.#{@current_method[1]}(#{@current_method[2..-1].join(", ")})}")
			  if dumped_succ
			      Roby::Distributed.debug "failed to dump #{result}"
			  else
			      Roby::Distributed.debug "failed to dump #{succ}"
			  end

			  new_exception.set_backtrace(backtrace)
			  dump(nil) + dump(new_exception, true)
		      end

		stream.write(str)
	    rescue
		raise(DRbConnError, $!.message + " while replying to #{@current_method}", $!.backtrace)
	    end

	    def send_request(*args)
		@current_method = args
		super
	    end

	    def recv_reply(*args)
		super
	    rescue
		raise $!, $!.message.to_s + " while receiving reply of #{@current_method}", $!.backtrace
	    end
	end

	class RobyProtocol < DRb::DRbTCPSocket
	    def self.parse_uri(uri)
		if uri =~ /^roby:\/\/(.*?):(\d+)(\?(.*))?$/
		    host = $1
		    port = $2.to_i
		    option = $4
		    [host, port, option]
		else
		    raise(DRb::DRbBadScheme, uri) unless uri =~ /^roby:/
		    raise(DRb::DRbBadURI, 'can\'t parse uri:' + uri)
		end
	    end

	    def self.uri_option(uri, config)
		host, port, option = parse_uri(uri)
		return "roby://#{host}:#{port}", option
	    end

	    def initialize(uri, soc, config = {})
		super
		@msg = Roby::Distributed::DRbMessage.new(config)
	    end
	    
	    # Open a server listening for connections at +uri+ using 
	    # configuration +config+.
	    def self.open_server(uri, config)
		uri = 'roby://:0' unless uri
		host, port, opt = parse_uri(uri)
		if host.size == 0
		    host = getservername
		    soc = open_server_inaddr_any(host, port)
		else
		    soc = TCPServer.open(host, port)
		end
		port = soc.addr[1] if port == 0
		uri = "roby://#{host}:#{port}"
		self.new(uri, soc, config)
	    end

	    def recv_request
		@current_method = @msg.recv_request(stream)
	    end
	end
	DRb::DRbProtocol.add_protocol(RobyProtocol)

	allow_remote_access Rinda::TupleSpace
	allow_remote_access Rinda::TupleEntry

    end
end

