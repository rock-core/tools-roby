require 'roby/task'
require 'roby/event'

# The Transactions module define all tools needed to implement
# the Transaction class
module Roby::Transactions
    # In transactions, we do not manipulate plan objects like Task and EventGenerator directly,
    # but through proxies which make sure that nothing forbidden is done
    #
    # The Proxy module define base functionalities for these proxy objects
    module Proxy
	@@proxy_klass = []
	@@proxys	  = Hash.new

	# Returns the proxy for +object+. Raises ArgumentError if +object+ is
	# not an object which should be wrapped
	def self.wrap(object)
	    if proxy = @@proxys[object]
		return proxy
	    end
	    all_proxys = @@proxy_klass.find_all { |_, real_klass| object.class.has_ancestor?(real_klass) }
	    if all_proxys.empty?
		raise ArgumentError, "no proxy for #{object.class}"
	    end

	    # Proxy#initialize adds us to @@proxy
	    all_proxys.last[0].new(object)
	end

	# Returns the proxy for +object+ if there is one, or +object+ itself
	def self.may_wrap(object)
	    wrap(object) rescue object
	end

	# Returns the object wrapped by +wrapper+
	def self.unwrap(wrapper); wrapper.__getobj__ end
	# If wrapper is a proxy, returns the wrapped object. Otherwise,
	# returns +object+ itself
	def self.may_unwrap(wrapper)
	    if wrapper.respond_to?(:__getobj__) then wrapper.__getobj__
	    else wrapper
	    end
	end

	# Declare that +proxy_klass+ should be used to wrap objects of +real_klass+.
	# Order matters: if more than one wrapping matches, we will use the one
	# defined last.
	def self.proxy_for(proxy_klass, real_klass)
	    @@proxy_klass << [proxy_klass, real_klass]
	end

	def initialize(object)
	    @@proxys[object] = self
	    @discovered = Hash.new
	    super(object)
	end

	# Fix DelegateClass#== so that comparing the same proxy works
	def ==(other)
	    if other.class.has_ancestor?(Proxy)
		self.eql?(other)
	    else
		__getobj__ == other
	    end
	end

	# Remove this proxy object
	def discard; @@proxys.delete(__getobj__) end

	def discovered?(relation)
	    @discovered[relation]
	end
	def discover(relation)
	    unless discovered?(relation)
		@discovered[relation] = true

		__getobj__.each_parent_object(relation) do |parent|
		    wrapper = Proxy.wrap(parent)
		    wrapper.add_child_object(self, relation, parent[__getobj__, relation])
		end
		__getobj__.each_child_object(relation) do |child|
		    wrapper = Proxy.wrap(child)
		    add_child_object(wrapper, relation, __getobj__[child, relation])
		end
	    end
	end

	module ClassExtension
	    def proxy_for(klass); Proxy.proxy_for(self, klass) end

	    def proxy_code(m)
		"args = args.map(&Proxy.method(:may_unwrap))
		result = if block_given?
			     __getobj__.#{m}(*args) { |*objects| yield(*objects.map(&Proxy.method(:may_wrap))) }
			 else
			     __getobj__.#{m}(*args)
			 end
		Proxy.may_wrap(result)"
	    end

	    def proxy(*methods)
		methods.each do |m|
		    class_eval "def #{m}(*args); #{proxy_code(m)} end"
		end
	    end

	    def proxy_component(*methods)
		methods.each do |m|
		    class_eval <<-EOD
		    def #{m}(relation) 
			# Discover all tasks that are supposed to be in the
			# component on the real object, and then compute
			# the component on this graph
			__getobj__.#{m}(relation).each do |task|
			    Proxy.wrap(task).discover(relation)
			end
			super
		    end
		    EOD
		end
	    end

	    def discover_before(*methods)
		methods.each do |m|
		    class_eval <<-EOD
		    def #{m}(*args)
			args.each { |rel| discover(rel) if Roby::RelationGraph === rel }
			super
		    end
		    EOD
		end
	    end

	    # +methods+ should not be called on the proxy
	    def forbid_call(*methods)
		methods.each do |m|
		    class_eval <<-EOD
			def #{m}(*args, &block)
			    raise NotImplementedError, "calls to #{m} are forbidden in transactions" 
			end
		    EOD
		end
	    end
	end

	extend ClassExtension

	proxy_component :component
	proxy_component :directed_component
	proxy_component :reverse_directed_component

	discover_before :child_object?
	discover_before :parent_object?
	discover_before :related_object?
	discover_before :each_child_object
	discover_before :each_parent_object
    end

    # Proxy for Roby::EventGenerator
    class EventGenerator < DelegateClass(Roby::EventGenerator)
	Roby::EventStructure.apply_on self

	include Proxy
	proxy_for Roby::EventGenerator

	forbid_call :call
	forbid_call :emit
    end

    # Proxy for Roby::Task
    class Task < DelegateClass(Roby::Task)
	Roby::TaskStructure.apply_on self

	include Proxy
	proxy_for Roby::Task

	proxy :event
	proxy :each_event
	proxy :fullfills?

	forbid_call :emit

	def self.forbidden_command
	    raise NotImplementedError, "calling event commands is forbidden in a transaction"
	end

	def initialize(object)
	    super
	    object.singleton_class.enum_for(:each_event).
		find_all { |_, ev| ev.controlable? }.
		each do |name, _|
		    instance_eval <<-EOD
		    def self.#{name}!(context); Task.forbidden_command end
		    EOD
		end
	end

	def method_missing(m, *args, &block)
	    if m.to_s =~ /^(\w+)!$/ && has_event?($1) && 
	        __getobj__.model.event_model($1).controlable?
	        raise NotImplementedError, "it is forbidden to call an event command when in a transaction"
	    else
	        super
	    end
	end
    end

end

