require 'drb'
require 'rinda/tuplespace'
require 'utilrb/value_set'
require 'roby/droby'

require 'roby'

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
	inject({}) { |h, (k, v)| h[peer.proxy(k)] = peer.proxy(v); h }
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
		tagdef.each do |name, remote_tag|
		    tag = DRoby.local_tag(name, remote_tag) do |tag|
			including.each { |mod| tag.include mod }
		    end
		    including << tag
		end
		including.last
	    end

	    def self.local_tag(name, remote_tag)
		if !remote_tag.kind_of?(Distributed::RemoteID)
		    remote_tag
		elsif local_model = TaskModelTag.remote_to_local[remote_tag]
		    local_model
		else
		    if name && !name.empty?
			local_model = constant(name) rescue nil
		    end
		    unless local_model
			local_model = Roby::TaskModelTag.new do
			    define_method(:name) { name }
			end
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
		    if mod.instance_of?(Roby::TaskModelTag)
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
	class DRoby
	    attr_reader :args
	    def initialize(args); @args = args end
	    def _dump(lvl); Marshal.dump(args) end

	    def self._load(str)
		setup_matcher(TaskMatcher.new, Marshal.load(str))
	    end
	    def self.setup_matcher(matcher, args)
		model, args, improves, needs, predicates, neg_predicates, owners = *args
		model  = model.proxy(nil) if model
		owners = owners.proxy(nil) if owners
		args   = args

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
	DEBUG_MARSHALLING = false

	class Peer
	    class DRoby
		attr_reader :name, :peer_id
		def initialize(name, peer_id); @name, @peer_id = name, peer_id end
		def hash; peer_id.hash end
		def eql?(obj); obj.respond_to?(:peer_id) && peer_id.eql?(obj.peer_id) end

		def to_s; "#<dRoby:Peer #{name} #{peer_id}>" end 
		def proxy(peer)
		    if peer = Distributed.peer(peer_id)
			peer
		    else
			raise "unknown peer ID #{peer_id}, known peers are #{Distributed.peers}"
		    end
		end
	    end

	    def droby_dump(dest = nil)
		@__droby_marshalled__ ||= DRoby.new(remote_name, remote_id)
	    end
	end

	# Dumps a constant by using its name
	class DRobyConstant
	    @@valid_constants = Hash.new
	    def self.valid_constants; @@valid_constants end
	    def to_s; "#<dRoby:Constant #{name}>" end

	    module Dump
		def droby_dump(dest)
		    unless DRobyConstant.valid_constants[self]
			if const_obj = (constant(name) rescue nil)
			    DRobyConstant.valid_constants[self] = DRobyConstant.new(name)
			else
			    raise ArgumentError, "invalid constant name #{obj.name}"
			end
		    end
		    DRobyConstant.valid_constants[self]
		end
	    end

	    attr_reader :name
	    def initialize(name); @name = name end
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
	    # A name -> class map which maps remote models to local anonymous classes
	    # Remote models are always identified by their name
	    @@remote_to_local = Hash.new
	    # A class => ID object which maps the anonymous classes we built for remote
	    # models to the remote ID of these remote models
	    @@local_to_remote = Hash.new

	    def self.remote_to_local; @@remote_to_local end
	    def self.local_to_remote; @@local_to_remote end
	    def to_s; "#<dRoby:Model #{ancestors.first.first}" end

	    module Dump
		def droby_dump(dest)
		    unless @__droby_marshalled__
			formatted = ancestors.map do |klass| 
			    if klass.instance_of?(Class) && !klass.is_singleton? 
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

	    attr_reader :ancestors
	    def initialize(ancestors); @ancestors  = ancestors end
	    def _dump(lvl); @__droby_marshalled__ ||= Marshal.dump(@ancestors) end
	    def self._load(str); DRobyModel.new(Marshal.load(str)) end
	    def proxy(peer)
	       	DRobyModel.local_model(ancestors.map { |name, id| [name, id.local_object] }) 
	    end

	    def ==(other)
		other.kind_of?(DRobyModel) &&
		    ancestors == other.ancestors
	    end
	    
	    def self.local_model(ancestors)
		name, id = ancestors.shift
		if !id.kind_of?(Distributed::RemoteID)
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
	Roby::EventGenerator.extend Distributed::DRobyModel::Dump
	Roby::Planning::Planner.extend Distributed::DRobyModel::Dump

	# Dumping intermediate for Task classes. This dumps both the ancestor list via
	# DRobyModel and the list of task tags.
	class DRobyTaskModel < DRobyModel
	    attr_reader :tags
	    def initialize(tags, ancestors)
		super(ancestors)
		@tags = tags
	    end

	    module Dump
		include DRobyModel::Dump
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

	    def ==(other)
		super &&
		    tags == other.tags
	    end

	    def _dump(lvl); @__droby_marshalled__ ||= Marshal.dump([tags, ancestors]) end
	    def self._load(str); DRobyTaskModel.new(*Marshal.load(str)) end

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

