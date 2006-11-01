require 'roby/task'
require 'roby/event'
require 'delegate'
require 'utilrb/module/ancestor_p'

# The Transactions module define all tools needed to implement
# the Transaction class
module Roby::Transactions
    # In transactions, we do not manipulate plan objects like Task and EventGenerator directly,
    # but through proxies which make sure that nothing forbidden is done
    #
    # The Proxy module define base functionalities for these proxy objects
    module Proxy
	@@proxy_klass = []
	@@forwarders  = Hash.new

	def to_s; "Proxy(#{__getobj__.to_s})" end

	# Returns the proxy for +object+. Raises ArgumentError if +object+ is
	# not an object which should be wrapped
	def self.proxy_class(object)
	    all_proxys = @@proxy_klass.find_all { |_, real_klass| object.kind_of?(real_klass) }
	    if all_proxys.empty?
		raise ArgumentError, "no proxy for #{object.class}"
	    end
	    all_proxys.last[0]
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
	    proxy_klass.extend Forwardable
	end

	# Returns a class that forwards every calls to +proxy.__getobj__+
	def self.forwarder(proxy)
	    klass = proxy.__getobj__.class
	    @@forwarders[klass] ||= DelegateClass(klass)
	    @@forwarders[klass]
	end

	def initialize(object, transaction)
	    @discovered  = Hash.new
	    @transaction = transaction
	    @__getobj__ = object
	end
	attr_reader :transaction
	attr_reader :__getobj__

	# Fix DelegateClass#== so that comparing the same proxy works
	def ==(other)
	    if other.kind_of?(Proxy)
		self.eql?(other)
	    else
		__getobj__ == other
	    end
	end

	def disable_discovery!
	    relations.each { |rel| @discovered[rel] = true }
	end
	def discovered?(relation)
	    @discovered[relation]
	end
	def discover(relation)
	    if @discovered.empty?
		transaction.discovered_object(self)
	    end
	    if !relation
		__getobj__.each_relation(&method(:discover))
		return
	    end

	    unless discovered?(relation)
		if relation.parent && !discovered?(relation.parent)
		    return discover(relation.parent)
		end

		@discovered[relation] = true
		relation.subsets.each { |rel| discover(rel) }

		# Bypass add_ and remove_ hooks by using the RelationGraph#link
		# methods directly. This is needed because we don't really
		# add new relations, but only copy already existing relations
		# from the real plan to the transaction graph
		__getobj__.each_parent_object(relation) do |parent|
		    wrapper = transaction[parent]
		    relation.link(wrapper, self, parent[__getobj__, relation])
		end
		__getobj__.each_child_object(relation) do |child|
		    wrapper = transaction[child]
		    relation.link(self, wrapper, __getobj__[child, relation])
		end
	    end
	end

	module ClassExtension
	    def proxy_for(klass); Proxy.proxy_for(self, klass) end

	    def proxy_code(m)
		"args = args.map(&Proxy.method(:may_unwrap))
		result = if block_given?
			     __getobj__.#{m}(*args) do |*objects| 
				objects.map! { |o| transaction.may_wrap(o) }
				yield(*objects)
			     end
			 else
			     __getobj__.#{m}(*args)
			 end
		transaction.may_wrap(result)"
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
			# the component on the transaction graph
			__getobj__.#{m}(relation).each do |task|
			    transaction[task].discover(relation)
			end
			super
		    end
		    EOD
		end
	    end

	    def discover_before(m, relation = nil)
		if Roby::RelationGraph === relation || !relation
		    class_eval do
			class_variable_set("@@_#{m}_discovered_relation_", relation)
		    end
		    class_eval <<-EOD
			def #{m}(*args, &block)
			    discover(@@_#{m}_discovered_relation_)
			    super
			end
		    EOD
		elsif relation.kind_of?(Integer)
		    class_eval <<-EOD
		    def #{m}(*args, &block)
			discover(args[#{relation}])
			super
		    end
		    EOD
		else
		    raise ArgumentError, "invalid value #{relation}"
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

	def relation_discover(other, type, unused = nil)
	    discover(type)
	    other.discover(type) if other.kind_of?(Proxy)
	end
	def adding_child_object(other, type, info)
	    relation_discover(other, type)
	    super if defined? super
	end
	def adding_parent_object(other, type, info)
	    relation_discover(other, type)
	    super if defined? super
	end
	def removing_child_object(other, type)
	    relation_discover(other, type)
	    super if defined? super
	end
	def removing_parent_object(other, type)
	    relation_discover(other, type)
	    super if defined? super
	end

	discover_before :child_object?, 1
	discover_before :parent_object?, 1
	discover_before :related_object?, 1
	discover_before :relations
	discover_before :each_relation
	discover_before :each_child_object, 0
	discover_before :each_parent_object, 0

	def commit_relations(enum, is_parent)
	    relations.each do |rel|
		next unless discovered?(rel)

		trsc_others = enum_for(enum, rel).to_value_set
		plan_others = __getobj__.enum_for(enum, rel).
		    map(&transaction.method(:[])).
		    to_value_set

		new = (trsc_others - plan_others)
		del = (plan_others - trsc_others)

		if is_parent
		    new.each do |other|
			__getobj__.add_child_object(Proxy.may_unwrap(other), rel, self[other, rel])
		    end
		    del.each do |other|
			__getobj__.remove_child_object(Proxy.may_unwrap(other), rel)
		    end
		else
		    new.each do |other|
			Proxy.may_unwrap(other).add_child_object(__getobj__, rel, other[self, rel])
		    end
		    del.each do |other|
			Proxy.may_unwrap(other).remove_child_object(__getobj__, rel)
		    end
		end
	    end
	end

	# Called when we need to commit modifications to the plan
	# Proxy#commit_transaction commits relation modification. Override in specific proxies if
	# more is needed
	def commit_transaction
	    commit_relations(:each_child_object, true)
	    commit_relations(:each_parent_object, false)
	end

	# Called when we need to discard the modifications. Proxy#commit
	# simply removes all relations
	def discard_transaction
	    clear_vertex
	end
    end

    # Proxy for Roby::EventGenerator
    class EventGenerator < Roby::EventGenerator
	include Proxy
	proxy_for Roby::EventGenerator
	
	def_delegator :@__getobj__, :symbol
	def_delegator :@__getobj__, :controlable?
	proxy :can_signal?
	discover_before :on, Roby::EventStructure::CausalLink

	forbid_call :call
	forbid_call :emit

	def commit_transaction
	    super
	    handlers.each { |h| __getobj__.on(&h) }
	end
    end

    # Proxy for Roby::Task
    class Task < Roby::Task
	include Proxy
	proxy_for Roby::Task

	def_delegator :@__getobj__, :running?
	def_delegator :@__getobj__, :finished?
	def_delegator :@__getobj__, :pending?
	def_delegator :@__getobj__, :model
	def_delegator :@__getobj__, :class
	def_delegator :@__getobj__, :arguments
	def_delegator :@__getobj__, :has_event?

	proxy :event
	proxy :each_event
	proxy :fullfills?
	proxy :same_state?

	forbid_call :emit
	forbid_call :start!
	forbid_call :failed!
	forbid_call :stop!
	forbid_call :success!

	def plan=(new_plan)
	    @plan = new_plan
	    each_event { |ev| ev.executable = executable? }
	end

	def self.forbidden_command
	    raise NotImplementedError, "calling event commands is forbidden in a transaction"
	end

	def discard_transaction
	    clear_relations
	end

	def method_missing(m, *args, &block)
	    if m.to_s =~ /^(\w+)!$/ && __getobj__.has_event?($1) && 
	        __getobj__.model.event_model($1).controlable?
	        raise NotImplementedError, "it is forbidden to call an event command when in a transaction"
	    else
	        super
	    end
	end
    end
end

