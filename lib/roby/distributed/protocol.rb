require 'drb'
require 'utilrb/value_set'
require 'roby/plan'

class Array
    class DRoby
	def initialize(object); @object = object end
	def _dump(lvl = -1)
	    marshalled = @object.map { |o| Roby::Distributed.dump(o) }
	    Marshal.dump(marshalled)
	end
	def self._load(str)
	    ary = Marshal.load(str)
	    ary.map! { |o| Marshal.load(o) }
	    ary
	end
    end
    def droby_dump; DRoby.new(self) end
    def proxy(peer)
	map { |o| peer.proxy(o) }
    end
end
class Hash
    class DRoby < Array::DRoby
	def initialize(hash); super(hash.to_a) end
	def self._load(str)
	    super.inject({}) { |h, (k, v)| h[k] = v; h }
	end
    end
    def droby_dump; DRoby.new(self) end
    def proxy(peer)
	inject({}) { |h, (k, v)| h[k] = peer.proxy(v); h }
    end
end
class Set
    class DRoby < Array::DRoby
	def self._load(str); super.to_set end
    end
    def droby_dump; DRoby.new(self) end
    def proxy(peer)
	map { |o| peer.proxy(o) }.to_set
    end
end
class ValueSet
    class DRoby < Array::DRoby
	def self._load(str); super.to_value_set end
    end
    def droby_dump; DRoby.new(self) end
    def proxy(peer)
	map { |o| peer.proxy(o) }.to_value_set
    end
end

class Class
    def droby_dump
	if ancestors.include?(Roby::Task) || ancestors.include?(Roby::EventGenerator)
	    Roby::Distributed::DRobyModel.new(ancestors)
	else
	    raise "can't dump class #{self}"
	end
    end
end


module Roby
    class RelationGraph
	def droby_dump
	    Distributed::DRobyConstant.new(self)
	end
    end

    class Plan
	# Distributed transactions are marshalled as DRbObjects and #proxy
	# returns their sibling in the remote pDB (or raises if there is none)
	class DRoby
	    def _dump(lvl); Marshal.dump(DRbObject.new(remote_object)) end
	    def self._load(str); new(Marshal.load(str)) end
	    def proxy(peer); peer.connection_space.plan end

	    attr_reader :remote_object
	    def initialize(remote_object)
		@remote_object = remote_object
	    end
	end
	def droby_dump
	    DRoby.new(self)
	end
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
		constant(Marshal.load(str))
	    end
	end

	class DRobyModel
	    @@models = Hash.new
	    attr_reader :ancestors

	    def initialize(ancestors); @ancestors = ancestors end
	    def _dump(lvl)
		marshalled = ancestors.map do |klass| 
		    next unless klass.instance_of?(Class) && !klass.is_singleton? 
		    klass.name 
		end
		Marshal.dump(marshalled.compact)
	    end
	    def self._load(str)
		ancestors = Marshal.load(str)
		if model = @@models[name] 
		    return model
		else
		    ancestors.each_with_index do |name, i|
			next unless !name.empty? && (model = constant(name) rescue nil)

			if i > 0
			    # The exact model is unknown. Create an anonymous class
			    model = Class.new(model)
			    @@models[name] = model
			end
			return model
		    end
		    raise TypeError, "cannot find model for #{ancestors}"
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
	    if object.kind_of?(DRb::DRbObject)
		Marshal.dump(object)
	    elsif object.respond_to?(:droby_dump)
		Marshal.dump(object.droby_dump)
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

	class MarshalledPlanObject
	    def self.droby_load(str)
		data = Marshal.load(str)
		object  = data[1]		    # the remote object
		data[2] = Marshal.load(data[2]) # the object model
		data[3] = Marshal.load(data[3]) # the object plan
		yield(data)
	    end

	    attr_reader :remote_name, :remote_object, :model, :plan
	    def initialize(remote_name, remote_object, model, plan)
		@remote_name, @remote_object, @model, @plan = 
		    remote_name, remote_object, model, plan
	    end
	    def to_s; "tMarshalled(#{remote_name})" end
	    def _dump(base_class)
		remote_object = self.remote_object
		remote_object = DRbObject.new(remote_object) unless remote_object.kind_of?(DRbObject)
		yield([remote_name, remote_object,
		    Distributed.dump(model),
		    Distributed.dump(plan)])
	    end

	    def proxy(peer)
		proxy = Distributed.RemoteProxyModel(model).new(peer, self)
		
		# marshalled.plan is nil if the object plan is determined by another
		# object. For instance, in the TaskEventGenerator case, the generator
		# plan is the task plan
		peer.proxy(plan).discover(proxy) if plan
		proxy
	    end
	    def ==(other)
		other.kind_of?(MarshalledPlanObject) && 
		    other.remote_object == remote_object
	    end
	end



	class MarshalledEventGenerator < MarshalledPlanObject
	    def self._load(str)
		droby_load(str) do |data|
		    if block_given? then yield(data)
		    else new(*data)
		    end
		end
	    end

	    def _dump(lvl)
		super(Roby::EventGenerator) do |ary|
		    ary << controlable << happened
		    if block_given? then yield(ary)
		    else Marshal.dump(ary)
		    end
		end
	    end

	    attr_reader :controlable, :happened
	    def initialize(remote_name, remote_object, model, plan, controlable, happened)
		super(remote_name, remote_object, model, plan)
		@controlable, @happened = controlable, happened
	    end
	end
	class Roby::EventGenerator
	    def droby_dump
		MarshalledEventGenerator.new(to_s, self, self.model, plan, controlable?, happened?(false))
	    end
	end

	class MarshalledTaskEventGenerator < MarshalledEventGenerator
	    def self._load(str)
		super do |data|
		    data[6] = Marshal.load(data[6])
		    new(*data)
		end
	    end
	    def _dump(lvl)
		super do |ary|
		    Marshal.dump(ary << Distributed.dump(task) << symbol)
		end
	    end

	    def proxy(peer)
		task = peer.proxy(self.task)
		ev   = task.event(symbol)
		if task.kind_of?(RemoteObjectProxy)
		    ev.extend EventGeneratorProxy
		    ev.initialize_remote_proxy(peer, self)
		end
		ev
	    end

	    attr_reader :task, :symbol
	    def initialize(name, remote_object, model, plan, controlable, happened, task, symbol)
		super(name, remote_object, model, plan, controlable, happened)
		@task   = task
		@symbol = symbol
	    end
	end
	class Roby::TaskEventGenerator
	    def droby_dump
		# no need to marshal the plan, since it is the same than the event task
		MarshalledTaskEventGenerator.new(to_s, self, self.model, nil, controlable?, happened?(false), task, symbol)
	    end
	end

	class MarshalledTask < MarshalledPlanObject
	    def self._load(str)
		droby_load(str) do |data|
		    data[4] = Marshal.load(data[4]) # the argument hash
		    MarshalledTask.new(*data)
		end
	    end

	    def _dump(lvl)
		super(Roby::Task) do |ary|
		    Marshal.dump(ary << Roby::Distributed.dump(arguments) << mission)
		end
	    end
	
	    def proxy(peer)
		task = super

		task.plan.insert(task) if mission && task.plan
		task
	    end

	    attr_reader :arguments, :mission
	    def initialize(remote_name, remote_object, model, plan, arguments, mission)
		super(remote_name, remote_object, model, plan)
		@arguments, @mission = arguments, mission
	    end
	end
	class Roby::Task
	    def droby_dump
		mission = self.plan.mission?(self) if plan
		MarshalledTask.new(to_s, self, self.model, plan, arguments, mission)
	    end
	end

    end
end

