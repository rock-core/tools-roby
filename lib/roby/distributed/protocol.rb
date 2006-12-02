require 'drb'
require 'utilrb/value_set'

class Array
    def droby_dump
	Marshal.dump(Roby::Distributed::DRobyArray.new(self))
    end
end
class Hash
    def droby_dump
	Marshal.dump(Roby::Distributed::DRobyHash.new(self))
    end
end
class ValueSet
    def droby_dump
	Marshal.dump(Roby::Distributed::DRobyValueSet.new(self))
    end
end

class Roby::RelationGraph
    def droby_dump
	Marshal.dump(Roby::Distributed::DRobyConstant.new(self))
    end
end

module Roby
    module Distributed
	class DRobyConstant
	    def initialize(obj)
		if const_obj = (constant(obj.name) rescue nil)
		    @obj = obj
		else
		    raise ArgumentError, "invalid constant name #{obj.name}"
		end
	    end
	    def _dump(lvl = -1)
		Marshal.dump(@obj.name)
	    end
	    def self._load(str)
		name = Marshal.load(str)
		constant(name)
	    end
	end
	class DRobyArray
	    def initialize(array)
		@array = array
	    end
	    def _dump(lvl = -1)
		marshalled = @array.map do |o|
		    Distributed.dump(o)
		end
		Marshal.dump(marshalled)
	    end
	    def self._load(str)
		Marshal.load(str).map { |o| Marshal.load(o) }
	    end
	end

	class DRobyValueSet
	    def initialize(value_set)
		@value_set = value_set
	    end
	    def _dump(lvl = -1)
		Distributed.dump(@value_set.to_a)
	    end
	    def self._load(str)
		Marshal.load(str).to_value_set
	    end
	end

	class DRobyHash
	    def initialize(hash)
		@hash = hash
	    end
	    def _dump(lvl = -1)
		Distributed.dump(@hash.to_a)
	    end
	    def self._load(str)
		Marshal.load(str).
		    inject({}) { |h, (k, v)| h[k] = v; h }
	    end
	end

	class DRobyModel
	    def initialize(model); @model = model end
	    def _dump(lvl)
		marshalled = []
		@model.ancestors.each do |klass|
		    marshalled << if klass.kind_of?(Class) && klass == (constant(klass.name) rescue nil)
				      klass.name
		    end
		end
		Marshal.dump(marshalled.compact)
	    end
	    def _load(str)
		Marshal.load(str).each do |name|
		    mod = constant(name) rescue nil
		    return mod if mod
		end
	    end
	end

	def self.marshallable?(object)
	    if object.respond_to?(:droby_dump)
		true
	    elsif object.kind_of?(DRbUndumped)
		false
	    else
		!!Marshal.dump(object) rescue nil
	    end
	end

	@allowed_remote_access = Array.new
	def self.allow_remote_access(type)
	    @allowed_remote_access << type
	end
	def self.allowed_remote_access?(object)
	    object.kind_of?(Exception) ||
		@allowed_remote_access.any? { |type| object.kind_of?(type) }
	end

	def self.dump(object, error = false)
	    if object.respond_to?(:droby_dump)
		object.droby_dump
	    else
		Marshal.dump(object)
	    end

	rescue
	    if allowed_remote_access?(object)
		return Marshal.dump(make_proxy(object, error))
	    elsif $!.kind_of?(TypeError)
		case $!.message
		when /can't dump$/
		    raise $!, "can't dump #{object.class}", $!.backtrace
		when /singleton can't be dumped$/
		    raise $!, "#{object.class} object can't be dumped because it has a singleton", $!.backtrace
		else
		    raise
		end
	    else
		raise
	    end
	end

	def self.make_proxy(obj, error=false)
	    if error
		DRb::DRbRemoteError.new(obj)
	    else
		DRb::DRbObject.new(obj)
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
			  dump(succ) + dump(result, !succ)
		      rescue
			  backtrace = $!.backtrace
			  new_exception = $!.exception($!.message + " calling #{@current_method}")
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
	allow_remote_access Roby::Plan

	def self.dump_ancestors(ancestors, base_class)
	    dumpable = []
	    ancestors.each do |klass|
		dumpable << if klass.kind_of?(Class) && klass == (constant(klass.name) rescue nil)
				klass.name
			    end
		break if klass == base_class
	    end
	    dumpable.compact
	end
	def self.load_ancestors(ancestors)
	    ancestors.map do |name|
		constant(name) rescue nil
	    end.compact
	end

	module MarshalledObject
	    module ClassExtension
		def droby_load(str)
		    data = Marshal.load(str)
		    object = data[0]
		    if !object.kind_of?(DRb::DRbObject)
			object
		    else
			data[1] = Distributed.load_ancestors(data[1])
			yield(data)
		    end
		end
	    end

	    attr_reader :remote_object, :ancestors, :plan
	    def initialize(remote_object, ancestors, plan)
		@remote_object, @ancestors, @plan = 
		    remote_object, ancestors, plan
	    end
	    def _dump(base_class)
		yield([DRbObject.new(remote_object),
		    Distributed.dump_ancestors(ancestors, base_class),
		    (DRbObject.new(plan) if plan)])
	    end

	    def proxy(peer)
		Distributed.RemoteProxyModel(ancestors.first).new(peer, self)
	    end

	    def ==(obj)
		obj.respond_to?(:remote_object) && remote_object == obj.remote_object
	    end
	end



	class MarshalledEventGenerator
	    include MarshalledObject
	    def self._load(str)
		droby_load(str) do |data|
		    if block_given? then yield(data)
		    else new(*data)
		    end
		end
	    end

	    def _dump(lvl)
		super(Roby::EventGenerator) do |ary|
		    ary << controlable
		    if block_given? then yield(ary)
		    else Marshal.dump(ary)
		    end
		end
	    end

	    attr_reader :controlable
	    def initialize(remote_object, ancestors, plan, controlable)
		super(remote_object, ancestors, plan)
		@controlable = controlable
	    end
	end
	class Roby::EventGenerator
	    def droby_dump(depth = -1)
		plan = self.plan
		plan = nil unless plan.kind_of?(Roby::Distributed::Transaction)
		Marshal.dump(MarshalledEventGenerator.new(self, self.class.ancestors, plan, controlable?))
	    end
	end



	class MarshalledTaskEventGenerator < MarshalledEventGenerator
	    include MarshalledObject
	    def self._load(str)
		super do |data|
		    data[4] = Marshal.load(data[4])
		    new(*data)
		end
	    end
	    def _dump(lvl)
		super do |ary|
		    Marshal.dump(ary << Distributed.dump(task) << symbol)
		end
	    end

	    def proxy(peer)
		peer.proxy(task).event(symbol)
	    end

	    attr_reader :task, :symbol
	    def initialize(remote_object, ancestors, plan, controlable, task, symbol)
		super(remote_object, ancestors, plan, controlable)
		@task   = task
		@symbol = symbol
	    end
	end
	class Roby::TaskEventGenerator
	    def droby_dump(depth = -1)
		# no need to marshal the plan, since it is the same than the event task
		Marshal.dump(MarshalledTaskEventGenerator.new(self, self.class.ancestors, nil, controlable?, task, symbol))
	    end
	end

	class MarshalledTask
	    include MarshalledObject
	    def self._load(str)
		droby_load(str) do |data|
		    data[3] = Marshal.load(data[3])
		    MarshalledTask.new(*data)
		end
	    end

	    def _dump(lvl)
		super(Roby::Task) do |ary|
		    Marshal.dump(ary << Roby::Distributed.dump(arguments) << mission)
		end
	    end

	    attr_reader :remote_object, :ancestors, :arguments, :mission
	    def initialize(remote_object, ancestors, plan, arguments, mission)
		super(remote_object, ancestors, plan)
		@arguments, @mission = arguments, mission
	    end
	end
	class Roby::Task
	    def droby_dump(depth = -1)
		plan = self.plan
		plan = nil unless plan.kind_of?(Roby::Distributed::Transaction)
		mission = self.plan.mission?(self) if plan

		Marshal.dump(MarshalledTask.new(self, self.class.ancestors, plan, arguments, mission))
	    end
	end

    end
end

