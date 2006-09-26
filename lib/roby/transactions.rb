require 'roby/event'
require 'roby/task'

module Roby

    # The Transactions module define all tools needed to implement
    # the Transaction class
    module Transactions
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
	    # Declare that +proxy_klass+ should be used to wrap objects of +real_klass+.
	    # Order matters: if more than one wrapping matches, we will use the one
	    # defined last.
	    def self.proxy_for(proxy_klass, real_klass)
		@@proxy_klass << [proxy_klass, real_klass]
	    end

	    def initialize(object)
		@@proxys[object] = self
		super(object)
	    end

	    # Fix DelegateClass#== so that comparing the same proxy works
	    def ==(other)
		if other.respond_to?(:__getobj__)
		    self.eql?(other)
		else
		    __getobj__ == other
		end
	    end

	    # Remove this proxy object
	    def discard; @@proxys.delete(__getobj__) end

	    module ClassExtension
		def proxy_for(klass); Proxy.proxy_for(self, klass) end

		# Wrap objects that are yield by the methods defined on the real object
		def proxy_iterator(*methods)
		    methods.each do |m|
			class_eval <<-EOD
			def #{m}(*args, &block)
			    result = __getobj__.#{m}(*args) { |*objects| yield(*objects.map(&Proxy.method(:may_wrap))) }
			    Proxy.may_wrap(result)
			end
			EOD
		    end
		end

		# Wrap objects returned by +methods+
		def proxy_forward(*methods)
		    methods.each do |m|
			class_eval <<-EOD
			def #{m}(*args, &block)
			    Proxy.may_wrap(__getobj__.#{m}(*args, &block))
			end
			EOD
		    end
		end

		# +methods+ should not be called on the proxy
		def forbid_call(*methods)
		    methods.each do |m|
			class_eval <<-EOD
			    def #{m}(*args, &block)
				raise NotImplementedError, "call to #{m} is forbidden in transaction proxys" 
			    end
			EOD
		    end
		end
	    end

	end

	# Proxy for Roby::EventGenerator
	class EventGenerator < DelegateClass(Roby::EventGenerator)
	    include Proxy
	    proxy_for Roby::EventGenerator

	    forbid_call :call
	end

	# Proxy for Roby::Task
	class Task < DelegateClass(Roby::Task)
	    include Proxy
	    proxy_for Roby::Task

	    proxy_forward  :event
	    proxy_iterator :each_event
	end
    end
end

